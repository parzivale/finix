# a providers.services implementation backed by runit
#
# runit is not an init: it supervises services underneath whatever is PID 1. it also has no
# dependency mechanism at all - every service directory in the scan directory is started in
# parallel, and ordering is conventionally each service's own problem, solved by polling for
# its prerequisites inside its own run script.
#
# so unlike the finit backend, which translates the contract onto finit's conditions, this one
# synthesises the whole dependency mechanism. every unit touches a latch file once it is up,
# and waits for the latch files of whatever it requires before doing anything. that is the same
# shape as the companion task on finit, except there is no condition system to borrow from and
# it has to be the filesystem.
#
# every supportedFeatures flag here that can be false is. it is the furthest the contract
# stretches.
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
  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);

  readinessLib = import ../../providers/services/readiness.nix {
    inherit pkgs lib;
  };
  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  # runit has no runlevels and no notion of a unit which is not to start yet: every directory in
  # the scan directory gets a runsv and is started at once. So a shutdown-side unit left in
  # there does not wait for the latch - it runs during boot, which is not late, it is wrong.
  #
  # They are kept out of the scan directory entirely and run from stage 3 instead, which is the
  # script runit executes as PID 1 on the way down.
  bootSide = lib.filterAttrs (name: unit: !(shutdownLib.onShutdownSide cfg.trunk name unit)) enabled;
  shutdownSide = lib.filterAttrs (name: unit: shutdownLib.onShutdownSide cfg.trunk name unit) enabled;

  # the shutdown side is part of the generation but not part of the supervised set: it is not
  # in the scan directory, because runit starts everything it finds there at boot.
  #
  # `list` reports it anyway, with the fingerprint this generation was built from. It is not
  # running - it never is, until the machine goes down - but it is also not something the
  # engine can start. Reporting nothing would leave it in the incoming tree and out of the
  # current one, so every switch would resolve to "start the shutdown side", forever. Reported
  # as already matching, the engine correctly finds nothing to do.
  reportShutdownSide = lib.concatStrings (
    lib.mapAttrsToList (
      name: _: "printf '%s\\t%s\\n' ${name} ${lib.escapeShellArg cfg.switch.fingerprints.${name}}\n"
    ) shutdownSide
  );

  shutdownScript = shutdownLib.scriptFor cfg;

  # runit has no dependency mechanism whatsoever. services are directories under a scan
  # directory, runsvdir starts a runsv for each, and they all come up in parallel - ordering is
  # conventionally each service's own problem, solved by polling for its prerequisites inside
  # its own run script.
  #
  # so the backend synthesises one. every unit touches a latch file once it is up, and every
  # unit waits for the latch files of whatever it requires before doing anything. that is the
  # same shape as the companion task on finit and the companion oneshot on systemd, except
  # there is no condition system to borrow and it has to be the filesystem.
  #
  # the latch is what makes the edge start-only, exactly as elsewhere: the file is created once
  # and never removed while the system runs, so a dependency dying later is not noticed.

  # a run script is the backend's own code and inherits whatever bare environment runsvdir
  # was given, so everything it invokes is named absolutely.
  mkdir = lib.getExe' pkgs.coreutils "mkdir";
  sleep = lib.getExe' pkgs.coreutils "sleep";
  touch = lib.getExe' pkgs.coreutils "touch";

  # runsv never calls setsid() on the process it execs - only on itself, and only under `-P` -
  # so a daemon inherits runsv's own session rather than getting one of its own. Most daemons
  # never notice, but anything which has to become a session leader to do its job - a tty's
  # `agetty` acquiring a controlling terminal via TIOCSCTTY chief among them - fails outright
  # without this. `setsid` itself only forks if it would otherwise be a process group leader
  # (sys-utils/setsid.c), which a script run this way never is, so this execs straight into the
  # same process rather than adding a fork the way `runsv -P` does.
  setsid = "${pkgs.util-linux}/bin/setsid";

  # `sv` resolves a bare service name through SVDIR, which defaults somewhere else entirely,
  # so every call names the directory outright.
  #
  # Two trees, which is why these are per-scope rather than the two constants they were. The
  # system's is pid 1's business and lives where only root can write; a user's belongs to one
  # session and lives under a directory of their own, because runsv writes into the tree it
  # supervises and a user has to be able to.
  systemScanDir = "/run/service";
  systemLatchDir = "/run/providers-services";

  # a user's root, created and chowned at boot - the one part of the user scope that needs root
  # and so cannot happen inside the session. The same convention the dinit backend uses, for the
  # same reason: one directory per user rather than one per system, so two users' trees are two
  # trees.
  userRoot = user: "/run/user-services/${user}";
  userScanDir = user: "${userRoot user}/service";
  userLatchDir = user: "${userRoot user}/latch";

  latch = latchDir: name: "${latchDir}/${name}.ready";

  # runit has no way to be told that a file appeared on its own, but something does:
  # `readinessLib.waitForPath` arms an inotify watch on the latch's directory rather than
  # polling for it, which is the same primitive this and `waitFor.path` both need.
  waitFor =
    latchDir: unit:
    lib.concatMapStrings (dep: readinessLib.waitForPath (latch latchDir dep)) unit.requires;

  # a unit runit considers "up" must not exit, or runsv restarts it forever. anchors and
  # completed oneshots therefore park rather than return.
  park = "exec ${sleep} infinity";

  # runit does not drop privileges itself; `chpst` ships with it for exactly this. without it
  # a unit asking to run as someone would run as root, which is the one failure here that is
  # worse than refusing outright.
  chpst = lib.getExe' pkgs.runit "chpst";
  asUser =
    unit:
    if unit.user == null then
      ""
    else
      "${chpst} -u ${unit.user}${lib.optionalString (unit.group != null) ":${unit.group}"} ";

  runScript =
    latchDir: name: unit:
    let
      kind = kindOf unit;
      v = variantOf unit;
    in
    pkgs.writeShellScript "${name}-run" (
      ''
        exec 2>&1
        ${lib.optionalString (unit.path != [ ]) "export PATH=${lib.makeBinPath unit.path}:\$PATH"}
        ${mkdir} -p ${latchDir}
        ${waitFor latchDir unit}
      ''
      + (
        if kind == "anchor" then
          ''
            ${touch} ${latch latchDir name}
            ${park}
          ''
        else if kind == "oneshot" then
          ''
            ${asUser unit}${v.command}
            ${touch} ${latch latchDir name}
            ${park}
          ''
        else if readinessOf unit == "waitFor" then
          ''
            # nothing to latch from once the daemon has been exec'd into, so the wait runs
            # alongside it and latches when whatever it is waiting for is live. runit observes
            # nothing itself - not even a forking daemon - so every waitFor kind is this.
            ( ${readinessLib.scriptFor name v.readiness}
              ${touch} ${latch latchDir name} ) &
            exec ${setsid} ${asUser unit}${v.command}
          ''
        else
          ''
            # `fork` readiness: up the moment it is running, which is what runit itself means
            # by a service being up. `notify` and `s6` never reach here - the contract refuses
            # them against this backend.
            ${touch} ${latch latchDir name}
            exec ${setsid} ${asUser unit}${v.command}
          ''
      )
    );

  # the service directories, assembled in the store and copied somewhere writable before
  # runsvdir scans them - runsv needs to create `supervise` inside each one.
  #
  # A function of the scope, because a user's tree is the same construction over a different
  # unit set with a different latch directory. Fingerprints are the system's alone: they exist
  # for `switch`, which reconciles the generation pid 1 is running, and a user's tree is not
  # reconciled - it is built when their session starts and goes when it ends.
  serviceTree =
    {
      label,
      units,
      latchDir,
      fingerprints ? null,
    }:
    pkgs.runCommand "runit-services-${label}" { } ''
      mkdir -p $out
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: unit: ''
          mkdir -p $out/${name}
          ln -s ${runScript latchDir name unit} $out/${name}/run
          ${lib.optionalString (fingerprints != null) ''
            printf '%s' ${lib.escapeShellArg fingerprints.${name}} > $out/${name}/fingerprint
          ''}
        '') units
      )}
    '';

  serviceDir = serviceTree {
    label = "system";
    units = bootSide;
    latchDir = systemLatchDir;
    fingerprints = cfg.switch.fingerprints;
  };

  sv = lib.getExe' pkgs.runit "sv";

  # `name<TAB>state` over a scan directory, which both scopes answer the same way: the words are
  # runsv's - `run` while the process is up, `down` when it is not, `finish` while its finish
  # script runs.
  #
  # The scan directory rather than the configured names, so a service directory put there by
  # hand is reported too. It is running on this machine whether or not a generation declared it,
  # and a listing which hid it would be the one thing this is for.
  statusScript =
    label: scanDir:
    toString (
      pkgs.writeShellScript "runit-status-${label}" ''
        for dir in ${scanDir}/*; do
          [ -d "$dir" ] || continue
          unit=$(${lib.getExe' pkgs.coreutils "basename"} "$dir")

          case "$(${sv} status "$dir" 2>/dev/null)" in
            run:*) state=running ;;
            finish:*) state=stopping ;;
            down:*) state=stopped ;;
            *) state=unknown ;;
          esac

          printf '%s\t%s\n' "$unit" "$state"
        done
      ''
    );

  # ---- the user scope ----------------------------------------------------------------
  #
  # runit supervises a user's tree the same way it supervises the system's, which is the whole
  # reason it can do this at all: runsvdir is a program that scans a directory, and nothing
  # about it wants to be pid 1 or to be root. What is different is where the tree lives and who
  # may write to it.
  userUnits = u: lib.filterAttrs (_: unit: unit.enable) u.units;

  userServiceDir =
    user: u:
    serviceTree {
      label = "user-${user}";
      units = userUnits u;
      latchDir = userLatchDir user;
    };

  # what a session runs, and it is not `runsvdir` directly for two reasons.
  #
  # The tree has to be copied out of the store first. `runsv` creates `supervise/` inside each
  # service directory it supervises, so a store path cannot be scanned - the same constraint
  # stage 1 handles for the system, done here instead because this is the first thing in the
  # session that is allowed to write to the user's directory.
  #
  # Copied per unit rather than as `rm -rf` and `cp -r`, which is what the system's stage 1 can
  # afford and this cannot: stage 1 runs once, before any supervisor exists, and this runs
  # whenever a session starts. A second session for the same user would otherwise delete the
  # tree the first one is being supervised from. Refreshing the files in place leaves a live
  # `supervise/` alone - and a second `runsvdir` over the same directory then finds every
  # service already locked and supervises nothing, which is noisy but harmless. One session per
  # user is what the launcher assumes; this is that assumption failing safely rather than
  # destructively.
  #
  # And the signals have to be translated, which is the part that would be silently wrong.
  # `sessionLauncher` stops a supervisor with SIGTERM, and runsvdir(8) is explicit about what
  # that means: "If runsvdir receives a TERM signal, it exits with 0 immediately" - leaving every
  # runsv, and so every one of the user's daemons, running with nothing supervising them. The
  # session would end, the supervisor would exit promptly and cleanly, and the tree would simply
  # stay. HUP is the signal that stops the tree: runsvdir sends TERM to each runsv and exits 111,
  # and runsv on TERM "acts as if the character x was written to the control pipe", which
  # terminates its service and exits. So TERM is caught here and HUP is what reaches runsvdir.
  #
  # Which is also why runsvdir is a child rather than an exec: a shell that has exec'd cannot
  # catch anything.
  userSupervisor =
    user: u:
    toString (
      pkgs.writeShellScript "runit-user-supervisor-${user}" ''
        set -e
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.runit
          ]
        }:$PATH

        ${mkdir} -p ${userLatchDir user} ${userScanDir user}

        # the latches from the last session, which have to go before this one's units start.
        # A latch is created once and never removed while a tree runs - that is what makes the
        # synthesised edges start-only - so one left behind by a session that has ended reads as
        # "this dependency is already up" to every unit waiting on it. The second session would
        # then start its whole tree at once, in no order at all, and pass: the units do come up,
        # and the ordering they were supposed to have is simply not there.
        #
        # Boot has the same problem and the system's stage 1 solves it by removing the scan
        # directory; this is the same removal for a scope that starts more than once.
        rm -f ${userLatchDir user}/*.ready

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: _: ''
            ${mkdir} -p ${userScanDir user}/${name}
            cp -fL ${userServiceDir user u}/${name}/run ${userScanDir user}/${name}/run
            chmod u+w ${userScanDir user}/${name}/run
          '') (userUnits u)
        )}

        # no `-P`, which stage 2 passes and this does not need. All it adds is a setsid() around
        # each runsv, and what that is for on the system side is a service which has to become a
        # session leader to acquire a controlling terminal - an agetty, which a session tree has
        # none of. The services themselves already get a session each: the run script execs
        # through setsid for exactly that. Leaving runsv in the session's own process group also
        # means a group-wide kill on logout reaches the tree, which is a backstop rather than
        # the mechanism - the launcher stopping this process is still what tears it down.
        ${pkgs.runit}/bin/runsvdir ${userScanDir user} &
        supervisor=$!

        trap '${lib.getExe' pkgs.coreutils "kill"} -HUP "$supervisor" 2>/dev/null || :' TERM INT

        # `wait` returns as soon as the trap has run, with the supervisor still being stopped -
        # so it is waited for again rather than once. Without the loop this returns the moment
        # the session asks it to stop, and the launcher's `kill -KILL` five seconds later would
        # be racing a teardown that had not finished.
        while ${lib.getExe' pkgs.coreutils "kill"} -0 "$supervisor" 2>/dev/null; do
          wait "$supervisor" || :
        done
      ''
    );

  # `sv` takes a subcommand and a service, and resolves a bare name through SVDIR - which is
  # what lets this be the `ctl` shape the contract asks for, a command taking `<verb> <unit>`.
  userCtl =
    user:
    toString (
      pkgs.writeShellScript "runit-user-ctl-${user}" ''
        export SVDIR=${userScanDir user}
        exec ${sv} "$@"
      ''
    );
in
{
  # enabling an implementation is what selects it: this names itself into the contract
  # below, the same way every other providers implementation does when it is enabled.
  options.runit.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether to boot runit as PID 1, through `runit-init`, supervising with `runsvdir`.

      Enabling it points {option}`providers.services.backend` at `runit`, which is what
      actually selects an implementation - so this is a default, and a machine naming a
      backend directly still wins.
    '';
  };

  # the same question for the user scope, and independent of the one above in both directions:
  # runsvdir is a program that scans a directory, so it serves a session beside any pid 1, and a
  # runit which *is* pid 1 does not serve a session unless this says so.
  #
  # Named for the role rather than as `runit.user.enable`, matching the dinit and systemd
  # modules.
  options.runit.userSupervisor.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether a `runsvdir` started by each user's session supervises that user's units.

      Enabling it points {option}`providers.services.user.backend` at `runit`, which is what
      actually selects an implementation for that scope - so this is a default, and a machine
      naming a backend directly still wins.

      Independent of {option}`runit.enable`. With no {option}`providers.services.users`
      declared it names an implementation for a scope with nothing in it, which is inert.
    '';
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "runit" ];
    };

    runit.serviceDir = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = ''
        The generated runit service directories.

        `runsv` creates a `supervise` directory inside each service directory, so this cannot
        be scanned out of the store: it must be copied somewhere writable first, and the copy
        must not be repeated while `runsvdir` is running, or the tree is deleted out from under
        it.

        Hosting is left to the system rather than done here, because runit is not an init and
        has to be supervised by whatever is. See `tests/providers/services-runit.nix` for the
        arrangement under `finit`:

        - a task which copies this somewhere writable, exactly once
        - a service running `runsvdir` over that copy, with `runit` on its `PATH`, since
          `runsvdir` execs `runsv` by name
      '';
    };
  };

  config = lib.mkMerge [
    # this module supplies an implementation for `providers.services`
    (lib.mkIf config.runit.enable {
      providers.services.backend = lib.mkDefault "runit";
    })

    # and the user scope, which is a separate claim - see `userSupervisor` above for why a
    # runsvdir per session beside a different pid 1 is the intended shape.
    (lib.mkIf config.runit.userSupervisor.enable {
      providers.services.user.backend = lib.mkDefault "runit";
    })

    (lib.mkIf (cfg.user.backend == "runit") {
      providers.services.user.manager.supervisor.command = user: userSupervisor user cfg.users.${user};
      providers.services.user.ctl = userCtl;
      providers.services.user.status = user: statusScript "user-${user}" (userScanDir user);

      # the user's root, which has to exist and belong to them before their session can write a
      # tree into it - and so is boot work, being the one part of this that needs root. The same
      # unit the dinit backend declares for the same reason; only one implementation serves this
      # scope on a machine, so only one of them is ever emitted.
      providers.services.units = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "user-services-dir--${user}" {
          description = "service directory for ${user}";
          requires = [ "sysinit" ];
          type.oneshot.command = pkgs.writeShellScript "user-services-dir-${user}" ''
            ${mkdir} -p ${userRoot user}
            ${lib.getExe' pkgs.coreutils "chown"} ${user} ${userRoot user}
          '';
        }
      ) cfg.users;
    })

    (lib.mkIf (cfg.backend == "runit") {
      providers.services.runit.serviceDir = serviceDir;

      providers.services.supportedFeatures = {
        # runit bounds neither: `sv -w` waits on the caller's side rather than the service's,
        # and stopping is SIGTERM then SIGKILL on a fixed schedule
        startTimeout = false;
        stopTimeout = false;

        # runit speaks neither protocol - it knows only that a process is running - so both are
        # refused by the contract rather than silently treated as `fork`. The rest are polled
        # from inside the run script.
        #
        # `waitFor.pidfile` is refused for a different reason, and is the one kind this cannot
        # fake: it says the daemon forks and the process runsv spawned exits. runsv reads that
        # exit as the service dying and starts it again, forever. The polling would succeed and
        # the supervision would be wrong, so refusing is the only honest answer.
        readiness = [
          "fork"
          "waitFor.socket"
          "waitFor.path"
          "waitFor.check"
        ];

        # through `chpst`, which ships with runit
        user = true;
        group = true;

        # the generated run script sets it before exec
        path = true;
      };

      # runit's own boot, which is three scripts run in order by `runit` - PID 1 - and nothing
      # else: stage 1 is one-time setup, stage 2 is the supervisor and is expected never to
      # return, stage 3 is teardown. The paths are fixed by runit and not configurable.
      # activation has to happen before runit-init rather than in stage 1, because the stage
      # scripts are themselves at /etc/runit/[123] - they are among the things activation puts
      # there, so runit could not find stage 1 to run it from.
      # an argv rather than a wrapper: `runit-init` needs nothing before it but the preamble
      # every backend needs, and finix-init is that. What this used to be was that preamble
      # written out again here - activation, then exec - which is the shape all of them had.
      providers.services.exec = [ "${pkgs.runit}/bin/runit-init" ];
      # runit is the only backend which ships nothing under these names. `runit-init` is the
      # whole interface: it writes /etc/runit/stopit, sets or clears the executable bit on
      # /etc/runit/reboot, and sends SIGCONT to PID 1, which wakes runit into stage 3.
      #
      # That it writes into /etc/runit is why this works at all - setup-etc symlinks leaf files
      # and makes the directories above them real, so the directory holding the stage scripts is
      # writable even though every script in it is a store symlink.
      #
      # halt and poweroff are the same call because runit draws no distinction: after stage 3 it
      # reads the bit on /etc/runit/reboot, and where that is clear it tries RB_POWER_OFF and
      # only falls back to RB_HALT_SYSTEM. There is no way to ask it for one and not the other.
      providers.services.shutdownCommands =
        let
          runitInit =
            arg:
            pkgs.writeShellScript "runit-${arg}" ''
              exec ${pkgs.runit}/bin/runit-init ${arg}
            '';
        in
        {
          poweroff = runitInit "0";
          halt = runitInit "0";
          reboot = runitInit "6";
        };

      environment.etc = {
        # stage 1. runsv creates `supervise` inside each service directory, so the generated tree
        # cannot be scanned out of the store and is copied somewhere writable first. Both these
        # directories have to exist before the first unit runs, which is why they are made here
        # rather than declared as tmpfiles rules - tmpfiles-setup is itself a unit, and could
        # only create them from inside the scan directory it would be creating.
        "runit/1".source = pkgs.writeShellScript "runit-stage-1" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          mkdir -p ${systemLatchDir}
          rm -rf ${systemScanDir}
          cp -rL ${serviceDir} ${systemScanDir}
          chmod -R u+w ${systemScanDir}
        '';

        # stage 2. runsvdir execs `runsv` by name for each service directory, so it needs runit
        # on PATH - which nothing else arranges, and this does for itself.
        #
        # `-P`: runsv never calls setsid() on its own, so without it every runsv - and everything
        # it in turn execs - stays in runsvdir's own session and process group. A service which
        # opens a controlling terminal for itself, like a tty's `agetty`, needs to be a session
        # leader with none yet for that to succeed; without `-P` it never is one, and acquiring a
        # ctty fails with EPERM/ENOTTY regardless of what the service does.
        "runit/2".source = pkgs.writeShellScript "runit-stage-2" ''
          export PATH=${lib.makeBinPath [ pkgs.runit ]}:$PATH
          exec ${lib.getExe' pkgs.runit "runsvdir"} -P ${systemScanDir}
        '';

        # stage 3. runit has already stopped the supervisor by the time this runs; the contract's
        # shutdown-side units are the graph's business, not runit's.
        # stage 3, which runit runs as PID 1 once the supervisor is gone - so the boot-side
        # services have already been stopped by the time this executes. That is the one point
        # runit reaches on the way down, and so where the contract's shutdown side belongs; it is
        # also why those units are excluded from the scan directory above, since anything left
        # there would have been started at boot instead.
        "runit/3".source = pkgs.writeShellScript "runit-stage-3" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          echo "runit: shutting down"
          ${lib.optionalString (shutdownScript != null) "${shutdownScript}"}
        '';
      };

      # `sv status` reports the first word, and `switch.list` below greps `^run:` for exactly
      # this. Shared with the user scope, which answers the same question over its own scan
      # directory - see `statusScript`.
      providers.services.ctl.status = statusScript "system" systemScanDir;

      providers.services.switch = {
        list = pkgs.writeShellScript "runit-list" ''
          ${reportShutdownSide}
          for dir in ${systemScanDir}/*; do
            [ -d "$dir" ] || continue
            unit=$(${lib.getExe' pkgs.coreutils "basename"} "$dir")
            ${sv} status "$dir" 2>/dev/null | ${lib.getExe' pkgs.gnugrep "grep"} -q '^run:' || continue

            # runsv decides what is running; the fingerprint only says which definition it was
            # started from. A service directory put here by hand has none, and skipping it would
            # make it invisible to the engine - never stopped, however the incoming tree changes.
            # `unknown` cannot equal a real fingerprint, so it is reconciled instead.
            if [ -e "$dir/fingerprint" ]; then
              printf '%s\t%s\n' "$unit" "$(cat "$dir/fingerprint")"
            else
              printf '%s\tunknown\n' "$unit"
            fi
          done
        '';

        activate = pkgs.writeShellScript "runit-activate" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

          while read -r unit; do
            # the scan directory is a writable copy made once, at boot - runsv keeps its own
            # state inside each service directory, so it cannot be scanned out of the store. A
            # unit which is new in this generation is therefore not in it, and starting it would
            # fail for want of anything to start. So the definition is brought across first.
            #
            # Only the files this backend generates are replaced, never the whole directory:
            # `supervise` belongs to a running runsv, and removing it out from under one loses
            # the process it is supervising.
            # a unit the engine names but this backend does not manage - the shutdown side, which
            # is kept out of the scan directory because runit would otherwise start it at boot
            if [ ! -d ${serviceDir}/"$unit" ] && [ ! -d ${systemScanDir}/"$unit" ]; then
              continue
            fi

            if [ -d ${serviceDir}/"$unit" ]; then
              mkdir -p ${systemScanDir}/"$unit"

              cp -fL ${serviceDir}/"$unit"/run ${systemScanDir}/"$unit"/run
              cp -fL ${serviceDir}/"$unit"/fingerprint ${systemScanDir}/"$unit"/fingerprint
              chmod u+w ${systemScanDir}/"$unit"/run ${systemScanDir}/"$unit"/fingerprint

              # runsvdir rescans on its own schedule - every five seconds - so a directory which
              # has just appeared has no runsv behind it yet, and `sv start` on it fails rather
              # than waiting. This waits for the supervisor to notice instead of racing it.
              for _ in $(seq 1 100); do
                if [ -e ${systemScanDir}/"$unit"/supervise/ok ]; then
                  break
                fi
                sleep 0.1
              done
            fi

            ${sv} start ${systemScanDir}/"$unit" || echo "start $unit failed" >&2
          done
        '';

        deactivate = pkgs.writeShellScript "runit-deactivate" ''
          while read -r unit; do
            ${sv} stop ${systemScanDir}/"$unit" || echo "stop $unit failed" >&2
            rm -f ${systemLatchDir}/"$unit".ready
          done
        '';
      };
    })
  ];
}
