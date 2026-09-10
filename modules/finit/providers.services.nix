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

  # `service/<name>/ready` is live: it de-asserts the moment the service stops, and finit acts
  # on that by stopping everything conditioned on it. the contract wants edges that gate
  # starting and nothing else, so each service gets a companion task which latches its readiness
  # once and never lets go. dependants condition on the companion, not on the service.
  companionOf = name: "${name}-started";

  conditionOf =
    name:
    if cfg.units.${name}.type == "service" then
      "task/${companionOf name}/success"
    else
      "task/${name}/success";

  common =
    name: unit:
    {
      inherit (unit) description;

      runlevels = runlevelsFor name unit;
      conditions = map conditionOf unit.requires;
      environment = unit.environment;
    }
    // lib.optionalAttrs (unit.user != null) { inherit (unit) user; }
    // lib.optionalAttrs (unit.group != null) { inherit (unit) group; };

  notify = {
    fork = "none";
    pidfile = "pid";
    notify = "systemd";
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
    conditions = [ "service/${name}/ready" ];
    command = true';
    remain = true;
  };

  isService = _: unit: unit.type == "service";

  bootSide = lib.filterAttrs (name: unit: !(onShutdownSide name unit)) cfg.units;
  shutdownSide = lib.filterAttrs onShutdownSide cfg.units;

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
      ) services;

    finit.run = lib.mkIf (shutdownSide != { }) {
      providers-services-shutdown = {
        description = "shutdown sequence";
        runlevels = shutdownRunlevels;
        command = shutdownScript;
      };
    };

    assertions = lib.mapAttrsToList (name: _: {
      assertion = !(cfg.units ? ${companionOf name});
      message = ''
        providers.services.units.${companionOf name} collides with the companion task the finit
        backend emits for providers.services.units.${name}. Rename one of them.
      '';
    }) services;
  };
}
