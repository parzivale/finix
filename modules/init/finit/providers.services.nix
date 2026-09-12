{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;

  tmpfilesReader = "${config.finit.package}/libexec/finit/tmpfiles";

  # handed to the reader by store path rather than left in /etc to be scanned, so that a rule
  # change changes the task's command. finit reconciles from its own configuration, so a stanza
  # whose text is identical between two generations is one it will not re-run.
  tmpfilesRules = pkgs.writeText "tmpfiles-finix.conf" ''
    # This file is created automatically and should not be modified.
    # Please change the option ‘finit.tmpfiles.rules’ instead.

    ${lib.concatStringsSep "\n" config.finit.tmpfiles.rules}
  '';

  # boot-side stanzas sit in every runlevel except 0 (halt) and 6 (reboot); the graph carries
  # all of the ordering, so finit's own sequencing is left with nothing to do. shutdown-side
  # stanzas sit in exactly 0 and 6, which is the only vocabulary finit has for "on the way out".
  bootRunlevels = "S12345789";
  shutdownRunlevels = "06";

  indexOf =
    name:
    lib.findFirst (i: i != null) null (lib.imap0 (i: l: if l == name then i else null) trunk.levels);

  latchIndex = indexOf trunk.latch;

  # a unit is on the shutdown side if it is a trunk level at or after the latch, or if it
  # attached itself to one. attaching to more than one level is refused by the contract, so
  # the first match is the only match.
  levelFor =
    name: unit:
    if lib.elem name trunk.levels then
      name
    else
      lib.findFirst (dep: lib.elem dep trunk.levels) null unit.requires;

  onShutdownSide =
    name: unit:
    let
      level = levelFor name unit;
    in
    latchIndex != null && level != null && indexOf level >= latchIndex;

  runlevelsFor = name: unit: if onShutdownSide name unit then shutdownRunlevels else bootRunlevels;

  # where a unit sits in the trunk, as a number. this orders the steps of the generated
  # shutdown script below; finit itself never sees it.
  priorityFor =
    name: unit:
    let
      i = indexOf (levelFor name unit);
    in
    if lib.elem name trunk.levels then i * 100 else i * 100 + 50;

  # finit has no process-less stanza, so an anchor is a task running `true`. `remain` stops it
  # re-running, and its `task/<name>/success` condition then holds for the rest of the runlevel.
  true' = lib.getExe' config.programs.coreutils.package "true";

  # every finit condition is live. `service/<n>/ready` de-asserts when the service stops, and
  # `task/<n>/success` de-asserts when the task is stopped or restarted; finit acts on either
  # by stopping whatever was conditioned on it. the contract's edges mean "this must have
  # started before I start", which is a statement about the past, so each unit gets a companion
  # task latching its readiness once, and dependants condition on the companion instead.
  #
  # this works because a companion's own success does not retract when the condition which
  # triggered it goes away - tests/providers/services.nix pins exactly that.
  #
  # every unit gets one, not only services. an anchor or oneshot depended upon directly would
  # drop its condition when restarted, and the switch engine restarts an anchor whenever a new
  # service attaches to its trunk level - which would otherwise stop everything hanging off it.
  companionOf = name: "${name}-started";

  conditionOf = name: "task/${companionOf name}/success";

  # the tag names the kind, and carries whatever that kind needs
  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};

  # what a companion waits for depends on how the unit it shadows reports being up
  readyConditionOf =
    name:
    if kindOf cfg.units.${name} == "service" then "service/${name}/ready" else "task/${name}/success";

  common =
    name: unit:
    {
      inherit (unit) description;

      runlevels = runlevelsFor name unit;
      conditions = map conditionOf unit.requires;
      environment = unit.environment;
    }
    // lib.optionalAttrs (unit.path != [ ]) { inherit (unit) path; }
    // lib.optionalAttrs (unit.user != null) { inherit (unit) user; }
    // lib.optionalAttrs (unit.group != null) { inherit (unit) group; };

  readinessLib = import ../../providers/services/readiness.nix { inherit pkgs lib; };

  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);
  waitKindOf = unit: lib.head (lib.attrNames (variantOf unit).readiness.waitFor);

  # the same, but safe to ask of any unit: null where readiness is not a waitFor at all
  waitKindOf' =
    unit: if kindOf unit == "service" && readinessOf unit == "waitFor" then waitKindOf unit else null;

  notify = {
    fork = "none";
    notify = "systemd";
    s6 = "s6";

    # finit observes a forking daemon itself; everything else under waitFor is waited for by
    # the companion below, so the service itself is up as soon as it is running.
    waitFor = "none";
  };

  mkService =
    name: unit:
    let
      svc = variantOf unit;
      ready = lib.head (lib.attrNames svc.readiness);
    in
    common name unit
    // {
      inherit (svc) command;
      notify = notify.${ready};
    }
    # a forking daemon is something finit observes for itself, so it is told rather than
    # waited for. The `!` matters: without it finit *manages* the pid file - creating it when
    # it starts the service and removing it when it stops - which would assert the condition
    # immediately and make the readiness meaningless. With it, the daemon writes the file and
    # finit watches for it, which is what was asked for.
    // lib.optionalAttrs (ready == "waitFor" && waitKindOf unit == "pidfile") {
      type = "forking";
      pid = "!${svc.readiness.waitFor.pidfile.file}";
    }
    // lib.optionalAttrs (unit.stopTimeout != null) { kill = unit.stopTimeout; };

  mkTask =
    name: unit:
    common name unit
    // {
      command = if kindOf unit == "anchor" then true' else (variantOf unit).command;
      remain = true;
    };

  # the shutdown side is emitted as a single stanza running a generated script, rather than as
  # one stanza per unit.
  #
  # finit will not carry an arbitrary-length sequence on the way down. conditioned tasks stop
  # cascading after a couple of hops, and `run` stanzas - documented as serialised - fare no
  # better: with four of them in finit.conf, in the right order, finit ran the first two and
  # then unmounted and powered off without touching the rest. see tests/providers/services.nix.
  #
  # so finit is asked to execute exactly one thing, and the ordering of the steps within it
  # becomes the shell's job, which is a guarantee that does hold.
  shutdownScript = pkgs.writeShellScript "providers-services-shutdown" (
    lib.concatMapStringsSep "\n"
      (unit: ''
        echo "shutdown: ${unit.description}" > /dev/kmsg 2>/dev/null || true
        ${unit.command}
      '')
      (
        lib.filter (unit: unit.command != null) (
          map (u: u // { command = (variantOf u).command or null; }) ordered
        )
      )
  );

  # priority is no longer an ordering finit acts on - it only sorts the script's steps here
  ordered = lib.sort (a: b: a.priority < b.priority) (
    lib.mapAttrsToList (name: unit: unit // { priority = priorityFor name unit; }) shutdownSide
  );

  # the companion latches a unit's readiness once, so that an edge means "this had started"
  # rather than "this is still running" - see the note above conditionOf.
  #
  # It is also where the waiting happens for the `waitFor` kinds finit cannot observe itself.
  # The service is up as soon as it is running; the companion then blocks until the socket
  # answers or the path appears, and only then does its condition assert. Since dependants
  # condition on the companion rather than the service, that is exactly the gate wanted -
  # and it costs nothing for the kinds which need no waiting, where the command is `true`.
  mkCompanion =
    name: unit:
    let
      wait =
        if kindOf unit == "service" then readinessLib.scriptFor name (variantOf unit).readiness else null;
    in
    {
      description = "${name} has started";

      runlevels = runlevelsFor name unit;
      conditions = [ (readyConditionOf name) ];
      command = if wait == null || waitKindOf' unit == "pidfile" then true' else wait;
      remain = true;
    };

  isService = _: unit: kindOf unit == "service";

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  bootSide = lib.filterAttrs (name: unit: !(onShutdownSide name unit)) enabled;
  shutdownSide = lib.filterAttrs onShutdownSide enabled;

  services = lib.filterAttrs isService bootSide;
in
{
  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "finit" ];
    };
  };

  options.finit.tmpfiles = {
    rules = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "d /tmp 1777 root root 10d" ];
      description = ''
        Rules for creation, deletion and cleaning of volatile and temporary files
        automatically. See {manpage}`tmpfiles.d(5)` for the exact format.

        Only read when finit is the selected backend, because reading them at all is a thing
        finit can do and the other implementations cannot - it ships a {manpage}`tmpfiles.d(5)`
        parser, and dinit, runit and s6 do not. Anything which should work under any init
        belongs in {option}`providers.services.tmpfiles.rules`, which is declared as attrsets
        lowered into commands at build time and so needs no parser at all.
      '';
    };

    clean = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable automatic cleaning of temporary files.

          :::{.note}
          You must have a scheduler backend configured with
          `providers.scheduler.backend` to utilize this option.
          :::
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = ''
          The interval at which this task should run its specified {option}`command`. Accepts either a
          standard {manpage}`crontab(5)` expression or one of: `hourly`, `daily`, `weekly`, `monthly`, or `yearly`.

          If a standard {manpage}`crontab(5)` expression is provided this value will be passed directly
          to the `scheduler` implementation and execute exactly as specified.

          If one of the special values, `hourly`, `daily`, `monthly`, `weekly`, or `yearly`, is provided then the
          underlying `scheduler` implementation will use its features to decide when best to run.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.backend == "finit") {
      # backend is a bare string key, so only this module can say which binary it means.
      # Wiring it to boot.init is the contract's job, not this one's.
      providers.services.initExecutable = "${config.finit.package}/bin/finit";

      # finit ships all three, and they reach it over its own socket. They are on PATH anyway
      # through finit.package being in systemPackages - naming them here is what stops that
      # from being the reason they work, and so what stops them winning on a machine running
      # some other backend.
      providers.services.shutdownCommands = {
        poweroff = "${config.finit.package}/bin/poweroff";
        reboot = "${config.finit.package}/bin/reboot";
        halt = "${config.finit.package}/bin/halt";
      };

      providers.services.supportedFeatures = {
        # finit can bound how long a unit takes to die - `kill`, the SIGTERM to SIGKILL delay -
        # but has nothing to bound how long one takes to become ready
        startTimeout = false;
        stopTimeout = true;

        # the only implementation which can observe everything. Both protocols are native, a
        # forking daemon is watched through `pid:!<file>`, and the kinds finit has no mechanism
        # for are waited out by the unit's companion task.
        readiness = [
          "fork"
          "notify"
          "s6"
          "waitFor.socket"
          "waitFor.pidfile"
          "waitFor.path"
          "waitFor.check"
        ];

        user = true;
        group = true;
        path = true;
      };

      # finit has no per-user mode. it runs a unit as a given user, which is what the first rule
      # for user units uses, but there is no per-user finit to be one user's own supervisor - so
      # it never claims the user scope.
      providers.services.user.supported = lib.mkDefault false;

      finit.services = lib.mapAttrs mkService services;

      finit.tasks =
        lib.mapAttrs mkTask (lib.filterAttrs (n: u: !(isService n u)) bootSide)
        // lib.mapAttrs' (name: unit: lib.nameValuePair (companionOf name) (mkCompanion name unit)) bootSide
        # the tmpfiles.d(5) rules only finit can read. Named apart from the contract's own
        # `tmpfiles-setup` unit, which finit also emits as a stanza - two stanzas of one name
        # is refused by the contract.
        // lib.optionalAttrs (config.finit.tmpfiles.rules != [ ]) {
          tmpfiles-finit.command = "${tmpfilesReader} --create ${tmpfilesRules}";
        };

      finit.run = lib.mkIf (shutdownSide != { }) {
        providers-services-shutdown = {
          description = "shutdown sequence";
          runlevels = shutdownRunlevels;
          command = shutdownScript;
        };
      };

      providers.scheduler.tasks = lib.mkIf config.finit.tmpfiles.clean.enable {
        tmpfiles-clean = {
          interval = config.finit.tmpfiles.clean.interval;
          command = "${tmpfilesReader} --clean ${tmpfilesRules}";
        };
      };

      # finit notices a changed unit by its stanza file changing, so stamping each unit's
      # fingerprint into its own file guarantees the file differs whenever the unit's definition
      # does - even for a change finit's own stanza would not otherwise reflect. this is the same
      # trick the openssh and tlp modules use to carry reload triggers, and it is also what a
      # real `list` would read back were finit ever to stop reconciling on its own.
      environment.etc = lib.mapAttrs' (
        name: unit:
        lib.nameValuePair "finit.d/${name}.conf" {
          text = lib.mkAfter "\n# fingerprint: ${cfg.switch.fingerprints.${name}}\n";
        }
      ) bootSide;

      # finit reconciles by itself: `initctl reload` re-reads /etc/finit.d and starts, stops and
      # restarts stanzas to match what it finds there - tests/finit/remain-after-exit.nix pins
      # that. so there is nothing for the engine to compute here, and the honest implementation
      # is to say so: report nothing running, let the engine hand over the whole tree, and reload
      # once. an init which does not self-reconcile, as dinit does not, gives a real `list` and
      # the engine's diff does the work instead.
      providers.services.switch = {
        list = pkgs.writeShellScript "finit-list" ":";

        activate = pkgs.writeShellScript "finit-reload" ''
          ${lib.getExe' config.finit.package "initctl"} reload
        '';

        deactivate = pkgs.writeShellScript "finit-reload" ''
          ${lib.getExe' config.finit.package "initctl"} reload
        '';
      };

      assertions = lib.mapAttrsToList (name: _: {
        assertion = !(cfg.units ? ${companionOf name});
        message = ''
          providers.services.units.${companionOf name} collides with the companion task the finit
          backend emits for providers.services.units.${name}. Rename one of them.
        '';
      }) bootSide;
    })

  ];
}
