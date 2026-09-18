# a providers.services implementation backed by OpenRC
#
# OpenRC is a dependency-driven init which is not PID 1 - it expects to be run by one, and
# ships `openrc-init` for machines with nothing else to do the job. That one runs `openrc
# sysinit`, then `openrc boot`, then the default runlevel, and then sits reaping children,
# which is exactly the shape the contract wants: something to be PID 1, and something to bring
# a graph of services up underneath it.
#
# Of the implementations here it is the closest to finit in what it offers natively - a real
# dependency system (`need`), a supervisor (`supervise-daemon`), and per-service users - so
# most of this is translation rather than synthesis. What it does not have is a readiness
# protocol: a service is started when its `start` returns, so every `waitFor` kind is a poll in
# `start_post`, and `notify`/`s6` are refused rather than pretended at.
#
# Runlevels are deliberately unused. OpenRC has them and the contract has a trunk, and the two
# say different things: a runlevel is a set a machine is in, a trunk level is a unit others
# wait for. Everything goes in `default` and the ordering comes from `need`, which is the
# contract's own graph rather than a second one beside it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};

  readinessLib = import ../../providers/services/readiness.nix {
    inherit pkgs lib;
    inherit (cfg) readinessPollInterval;
  };

  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  bootSide = lib.filterAttrs (name: unit: !(shutdownLib.onShutdownSide cfg.trunk name unit)) enabled;
  shutdownSide = lib.filterAttrs (name: unit: shutdownLib.onShutdownSide cfg.trunk name unit) enabled;

  # the shutdown side is part of the generation but not part of the runlevel: a service in
  # `default` is one openrc starts at boot, which is the one thing a unit on this side must
  # never do. It is lowered to a single script instead, in trunk order, and handed to the one
  # point openrc reaches reliably on the way down.
  #
  # That point is the `shutdown` runlevel. openrc-init runs `openrc shutdown` before it sends
  # the final TERM, and changing runlevel stops what the old one held before starting what the
  # new one does - so by the time this runs, everything it is supposed to come after has
  # stopped. Which is exactly what the latch means.
  shutdownScript = shutdownLib.scriptFor cfg;

  # `list` reports the shutdown side anyway, with the fingerprint this generation was built
  # from. It is not running - it never is, until the machine goes down - but it is also not
  # something the engine can start. Reporting nothing leaves it in the incoming tree and out of
  # the current one, so every switch resolves to "start the shutdown side", forever, against
  # services which are not in /etc/init.d at all: `starting: ... stopped ifupdown-ng-down
  # shutdown` on a switch that changed none of them. Reported as already matching, the engine
  # correctly finds nothing to do.
  reportShutdownSide = lib.concatStrings (
    lib.mapAttrsToList (
      name: _: "printf '%s\\t%s\\n' ${name} ${lib.escapeShellArg cfg.switch.fingerprints.${name}}\n"
    ) shutdownSide
  );

  openrc = config.openrc.package;

  # the runscripts of the generation which is actually running, kept out of the way of the one
  # being switched into. /etc/init.d cannot answer either question the engine asks:
  #
  #   what fingerprint is this unit running under? - activation rewrites /etc before the engine
  #   is asked anything, so reading it there describes the incoming generation. Every unit looks
  #   unchanged and nothing is ever reconciled.
  #
  #   what do I stop it with? - a unit the new generation drops is not in the new /etc/init.d at
  #   all, and openrc resolves a service to a script by name. The one it was started from is the
  #   only correct thing to stop it with, and this is where that is kept.
  #
  # Each script carries its own `# fingerprint:` line, so one directory answers both.
  runUnits = "/run/openrc-units";

  # `need` rather than `after`: the contract's edge means "do not start until this is ready",
  # which is what `need` says. `after` is ordering without a requirement, so a unit whose
  # dependency failed would start regardless.
  #
  # An edge naming a unit this backend does not emit - the shutdown side - would make openrc
  # refuse the service outright, so those are dropped rather than left dangling.
  dependsOf =
    unit:
    let
      real = lib.filter (dep: bootSide ? ${dep}) unit.requires;
    in
    if real == [ ] then
      # `:` rather than nothing. gendepends builds the dependency tree by sourcing each
      # runscript, and a shell function with an empty body is a syntax error - so a unit which
      # requires nothing would fail to source, drop out of the tree, and take down everything
      # that named it. The trunk's first level is exactly that unit, so the whole graph went
      # with it: "backdoor needs service(s) start", and the same for all 29.
      ":"
    else
      "need ${lib.concatStringsSep " " real}";

  # PATH is set in the script rather than asked of openrc, which has `rc_path` as a build-time
  # array and nothing per service. Units get a bare environment, so anything naming a program
  # rather than a path needs this.
  environmentOf =
    unit:
    lib.optionalString (unit.path != [ ]) ''
      export PATH=${lib.makeBinPath unit.path}''${PATH:+:$PATH}
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") unit.environment
    );

  # a `waitFor` is a poll after the command has been started, which is what start_post is for.
  # Returning non-zero there marks the service failed, which is the honest answer: it is
  # running and has not become ready, and whatever required it must not start.
  #
  # Only a service has readiness at all - a oneshot is ready once it has exited, an anchor once
  # what it requires is - so this is asked of nothing else.
  waitForBlock =
    name: unit:
    let
      v = variantOf unit;
    in
    lib.optionalString (lib.head (lib.attrNames v.readiness) == "waitFor") ''
      start_post() {
        ${readinessLib.scriptFor name v.readiness}
      }
    '';

  runscript =
    name: unit:
    let
      kind = kindOf unit;
      v = variantOf unit;
      # supervise-daemon wants the program and its arguments separately - it execs the one
      # and passes the others - where the contract carries both in a single `program` string.
      # Splitting on spaces is the reading that string is defined by: it admits "a command
      # with arguments" with no quoting convention layered on top, so a space is an argument
      # boundary and nothing else. An argument which needs to contain one has to arrive as a
      # script, which is how the contract expects anything non-trivial to be written anyway.
      words = lib.splitString " " v.command or "";
    in
    pkgs.writeScript "openrc-${name}" (
      ''
        #!${openrc}/bin/openrc-run

        description=${lib.escapeShellArg (if unit.description == null then name else unit.description)}

        depend() {
          ${dependsOf unit}
        }

        ${environmentOf unit}
      ''
      + (
        if kind == "anchor" then
          ''
            # an anchor has no process: it is a name which becomes ready once the units it
            # requires are, which `need` above has already said.
            start() {
              return 0
            }

            stop() {
              return 0
            }
          ''
        else if kind == "oneshot" then
          ''
            # openrc marks a service started when `start` returns successfully, which is what a
            # oneshot means: it has run, and whatever waited for it may go.
            start() {
              ${v.command}
            }

            stop() {
              return 0
            }
          ''
        else
          ''
            supervisor=supervise-daemon
            command=${lib.escapeShellArg (lib.head words)}
            command_args=${lib.escapeShellArg (lib.concatStringsSep " " (lib.tail words))}
            ${lib.optionalString (unit.user != null) ''
              command_user=${
                lib.escapeShellArg (unit.user + lib.optionalString (unit.group != null) ":${unit.group}")
              }
            ''}
            ${waitForBlock name unit}
          ''
      )
    );

  initd = pkgs.runCommand "openrc-init.d" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: unit: ''
        install -m 0755 ${runscript name unit} $out/${name}

        # the same fingerprint the engine compares, written where a person reading the
        # runscript will find it. What the engine actually reads is the /run copy, which
        # records what is *running* rather than what is installed - but a generated file
        # should say what generated it.
        printf '\n# fingerprint: %s\n' ${cfg.switch.fingerprints.${name}} >> $out/${name}
      '') bootSide
    )
    + lib.optionalString (shutdownScript != null) ''
      install -m 0755 ${shutdownRunscript} $out/providers-services-shutdown
    ''
  );

  # not a unit, and deliberately not named like one: the whole shutdown side is one script, and
  # this is the runscript which carries it into the `shutdown` runlevel. It has no `depend` -
  # there is nothing left to depend on by the time it runs.
  shutdownRunscript = pkgs.writeScript "openrc-providers-services-shutdown" ''
    #!${openrc}/bin/openrc-run

    description='the shutdown side of the trunk, in order'

    depend() {
      :
    }

    start() {
      ${shutdownScript}
    }

    stop() {
      return 0
    }
  '';

  # every unit in one runlevel: the ordering is the contract's graph, said in `need`, and a
  # second ordering in runlevels could only disagree with it
  runlevels = pkgs.runCommand "openrc-runlevels" { } (
    ''
      mkdir -p $out/default $out/sysinit $out/boot $out/shutdown
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: _: ''
        ln -s /etc/init.d/${name} $out/default/${name}
      '') bootSide
    )
    + lib.optionalString (shutdownScript != null) ''
      ln -s /etc/init.d/providers-services-shutdown $out/shutdown/providers-services-shutdown
    ''
  );
in
{
  options.openrc = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether to boot OpenRC, through `openrc-init` as PID 1.

        Enabling it points {option}`providers.services.backend` at `openrc`, which is what
        actually selects an implementation - so this is a default, and a machine naming a
        backend directly still wins.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../../../pkgs/openrc { };
      defaultText = lib.literalExpression "pkgs.callPackage ../../../pkgs/openrc { }";
      description = ''
        The OpenRC package to use.
      '';
    };
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "openrc" ];
    };
  };

  config = lib.mkMerge [
    # this module supplies an implementation for `providers.services`
    (lib.mkIf config.openrc.enable {
      providers.services.backend = lib.mkDefault "openrc";
    })

    (lib.mkIf (cfg.backend == "openrc") {
      providers.services.supportedFeatures = {
        # supervise-daemon has --respawn-max and a stop schedule, but neither bounds one unit's
        # own start or stop, which is what these mean
        startTimeout = false;
        stopTimeout = false;

        # a service is started when its `start` returns, so the waiting kinds are a poll in
        # start_post. `notify` and `s6` are protocols openrc does not speak, and
        # `waitFor.pidfile` says the daemon forks and the spawned process exits - which
        # supervise-daemon reads as the daemon dying.
        readiness = [
          "fork"
          "waitFor.socket"
          "waitFor.path"
          "waitFor.check"
        ];

        # command_user, which supervise-daemon takes as user:group
        user = true;
        group = true;

        path = true;
      };

      # activation first, for the same reason as every other implementation: /etc has to exist
      # before anything reads a service out of it.
      providers.services.initExecutable = pkgs.writeShellScript "openrc-init" ''
        ${cfg.activationScript}

        # the generation about to be started, recorded as the running one. Here rather than in
        # activation, which runs on every switch too - rewriting these then would tell the next
        # `list` that what is running was already what is being switched into.
        ${lib.getExe' pkgs.coreutils "rm"} -rf ${runUnits}
        ${lib.getExe' pkgs.coreutils "cp"} -rL ${initd} ${runUnits}
        ${lib.getExe' pkgs.coreutils "chmod"} -R u+w ${runUnits}

        exec ${openrc}/bin/openrc-init
      '';

      # `now` is not optional. Each of these takes a time to go down at - openrc-shutdown is
      # `shutdown(8)`, which schedules rather than acts - and without one it prints "No shutdown
      # time specified" and exits, leaving the machine up. The contract's commands mean do it,
      # so they say when: immediately.
      providers.services.shutdownCommands = {
        poweroff = "${openrc}/bin/openrc-shutdown --poweroff now";
        reboot = "${openrc}/bin/openrc-shutdown --reboot now";
        halt = "${openrc}/bin/openrc-shutdown --halt now";
      };

      # supervise-daemon and start-stop-daemon authenticate through PAM before dropping to a
      # unit's user, under a service name of their own. openrc ships a stack for each in its
      # own $out/etc/pam.d, which is not a directory anything on a finix machine reads - so the
      # lookup fell through to `other`, which denies, and every unit with a `user` failed with
      # "pam error: Authentication failure" while the daemon itself was perfectly fine.
      #
      # These are openrc's own files, transcribed. They authenticate nobody: the caller is
      # already root and has already decided who to run as, so there is no credential to check
      # and the stack exists to apply limits. `password` denies because changing one through
      # this path is not a thing either program does.
      security.pam.services = {
        supervise-daemon.text = ''
          auth      required  pam_permit.so
          account   required  pam_permit.so
          password  required  pam_deny.so
          session   optional  pam_limits.so
        '';

        start-stop-daemon.text = ''
          auth      required  pam_permit.so
          account   required  pam_permit.so
          password  required  pam_deny.so
          session   optional  pam_limits.so
        '';
      };

      environment.etc."init.d".source = initd;
      environment.etc."runlevels".source = runlevels;

      environment.systemPackages = [ openrc ];

      providers.services.switch = {
        # openrc's own listings are the wrong tool here, and quietly so. `rc-status
        # --servicelist` enumerates the scripts in /etc/init.d - the incoming generation - and
        # librc's directory walk skips any entry whose script has gone, on purpose: "a service
        # maybe in a runlevel, but could have been removed". A unit the new generation drops is
        # exactly that, and it is the one case the engine most needs told about.
        #
        # So the state directory is read directly. openrc records every started service as a
        # symlink there, and a plain listing does not care that the link now dangles.
        list = pkgs.writeShellScript "openrc-list" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.gnused
            ]
          }:$PATH

          ${reportShutdownSide}
          [ -d /run/openrc/started ] || exit 0

          for path in /run/openrc/started/*; do
            unit=$(basename "$path")
            [ "$unit" = '*' ] && continue

            # openrc decides what is running; the fingerprint only says which definition it was
            # started from, which no supervisor can be asked. So a missing record must not drop
            # the unit from the list - one started by hand has none, and skipping it makes it
            # invisible to the engine: never stopped when the incoming tree drops it, and
            # "started" as a no-op when it does not. `unknown` cannot equal a real fingerprint,
            # so the pair differs and the unit is reconciled either way.
            fp=unknown
            if [ -e ${runUnits}/"$unit" ]; then
              fp=$(sed -n 's/^# fingerprint: //p' ${runUnits}/"$unit")
            fi

            printf '%s\t%s\n' "$unit" "''${fp:-unknown}"
          done
        '';

        activate = pkgs.writeShellScript "openrc-activate" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              openrc
            ]
          }:$PATH

          while read -r unit; do
            rc-service "$unit" start || echo "  start $unit failed" >&2

            # what is now running, recorded where the next switch will look. After the start
            # rather than before, so a unit which failed to start is not claimed as this
            # generation's.
            if [ -e /etc/init.d/"$unit" ]; then
              mkdir -p ${runUnits}
              install -m 0755 /etc/init.d/"$unit" ${runUnits}/"$unit"
            fi
          done
        '';

        deactivate = pkgs.writeShellScript "openrc-deactivate" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              openrc
            ]
          }:$PATH

          while read -r unit; do
            # openrc keeps one symlink per started service in /run/openrc/started, and uses it
            # for both questions it asks about that service: whether it is running (a plain
            # access check, which follows the link) and what script to stop it with (the link's
            # target). Both point into the /etc/init.d of the generation which started the
            # unit - so for a unit this switch drops, the link now dangles, openrc answers
            # "already stopped", and the daemon goes on running with nothing left naming it.
            #
            # Repointed at this generation's own copy - the same script, somewhere the incoming
            # generation cannot take away - the link resolves and the stop is an ordinary one.
            if [ -L /run/openrc/started/"$unit" ] && [ ! -e /run/openrc/started/"$unit" ] && [ -x ${runUnits}/"$unit" ]; then
              ln -sfn ${runUnits}/"$unit" /run/openrc/started/"$unit"
            fi

            rc-service "$unit" stop || echo "  stop $unit failed" >&2

            # no longer running, so no longer this generation's
            rm -f ${runUnits}/"$unit"
          done
        '';
      };
    })
  ];
}
