{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;

  # boot-side stanzas sit in every runlevel except 0 (halt) and 6 (reboot); the graph carries
  # all of the ordering, so finit's own sequencing is left with nothing to do. shutdown-side
  # stanzas sit in exactly 0 and 6, which is the only vocabulary finit has for "on the way out".
  bootRunlevels = "S12345789";
  shutdownRunlevels = "06";

  indexOf =
    name:
    lib.findFirst (i: i != null) null (lib.imap0 (i: l: if l == name then i else null) trunk.levels);

  latchIndex = if trunk.enable then indexOf trunk.latch else null;

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

  # what a companion waits for depends on how the unit it shadows reports being up
  readyConditionOf =
    name:
    if cfg.units.${name}.type == "service" then "service/${name}/ready" else "task/${name}/success";

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

  notify = {
    fork = "none";
    pidfile = "pid";
    notify = "systemd";
    s6 = "s6";
  };

  mkService =
    name: unit:
    common name unit
    // {
      inherit (unit) command;
      notify = notify.${unit.readiness};
    }
    // lib.optionalAttrs (unit.readiness == "pidfile") {
      type = "forking";
      pid = unit.pidFile;
    }
    // lib.optionalAttrs (unit.stopTimeout != null) { kill = unit.stopTimeout; };

  mkTask =
    name: unit:
    common name unit
    // {
      command = if unit.type == "anchor" then true' else unit.command;
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
    lib.concatMapStringsSep "\n" (unit: ''
      echo "shutdown: ${unit.description}" > /dev/kmsg 2>/dev/null || true
      ${unit.command}
    '') (lib.filter (unit: unit.command != null) ordered)
  );

  # priority is no longer an ordering finit acts on - it only sorts the script's steps here
  ordered = lib.sort (a: b: a.priority < b.priority) (
    lib.mapAttrsToList (name: unit: unit // { priority = priorityFor name unit; }) shutdownSide
  );

  mkCompanion = name: unit: {
    description = "${name} has started";

    runlevels = runlevelsFor name unit;
    conditions = [ (readyConditionOf name) ];
    command = true';
    remain = true;
  };

  isService = _: unit: unit.type == "service";

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

  config = lib.mkIf (cfg.backend == "finit") {
    providers.services.supportedFeatures = {
      # finit can bound how long a unit takes to die - `kill`, the SIGTERM to SIGKILL delay -
      # but has nothing to bound how long one takes to become ready
      startTimeout = false;
      stopTimeout = true;

      # both emulated above, with a task running `true`
      nativeAnchors = false;
      nativeStartOnlyEdges = false;
    };

    finit.services = lib.mapAttrs mkService services;

    finit.tasks =
      lib.mapAttrs mkTask (lib.filterAttrs (n: u: !(isService n u)) bootSide)
      // lib.mapAttrs' (
        name: unit: lib.nameValuePair (companionOf name) (mkCompanion name unit)
      ) bootSide;

    finit.run = lib.mkIf (shutdownSide != { }) {
      providers-services-shutdown = {
        description = "shutdown sequence";
        runlevels = shutdownRunlevels;
        command = shutdownScript;
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
  };
}
