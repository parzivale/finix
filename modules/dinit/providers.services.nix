{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;

  # dinit's own vocabulary is close enough to the contract that the boot side needs no
  # emulation at all. `internal` is a process-less unit, so an anchor is one directly.
  # `depends-ms` is a milestone dependency - the named service must start successfully once,
  # and may stop afterwards without affecting this one - which is exactly an edge that gates
  # starting and nothing else. the finit backend has to fake both.
  type = {
    anchor = "internal";
    oneshot = "scripted";
    service = {
      fork = "process";
      pidfile = "bgprocess";
      notify = "process";
    };
  };

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};
  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);

  typeOf =
    unit: if kindOf unit == "service" then type.service.${readinessOf unit} else type.${kindOf unit};

  commandOf = unit: (variantOf unit).command or null;

  indexOf =
    name:
    lib.findFirst (i: i != null) null (lib.imap0 (i: l: if l == name then i else null) trunk.levels);

  latchIndex = if trunk.enable then indexOf trunk.latch else null;

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

  priorityFor =
    name: unit:
    let
      i = indexOf (levelFor name unit);
    in
    if lib.elem name trunk.levels then i * 100 else i * 100 + 50;

  # dinit has no runlevels, so the latch cannot be a unit which simply does not exist while
  # the system runs - anything reachable from the root service starts at boot. what it has
  # instead is `stop-command`, and a documented intent that shutdown work belongs there.
  #
  # so the shutdown side inverts: each post-latch unit starts as a no-op and does its real
  # work on the way down. dinit stops dependents before their dependencies, so to make the
  # stop order match the trunk's forward order, each unit depends on the one *after* it -
  # the reverse of how the boot side is wired.
  shutdownOrdered = lib.sort (a: b: a.priority < b.priority) (
    lib.mapAttrsToList (
      name: unit:
      unit
      // {
        inherit name;
        priority = priorityFor name unit;
      }
    ) (lib.filterAttrs onShutdownSide enabled)
  );

  successorOf =
    name:
    let
      i = lib.findFirst (x: x != null) null (
        lib.imap0 (x: u: if u.name == name then x else null) shutdownOrdered
      );
    in
    if i != null && i + 1 < lib.length shutdownOrdered then
      [ (lib.elemAt shutdownOrdered (i + 1)).name ]
    else
      [ ];

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  latchName = if shutdownOrdered == [ ] then null else (lib.head shutdownOrdered).name;

  true' = lib.getExe' pkgs.coreutils "true";

  mkBootSide =
    name: unit:
    {
      type = typeOf unit;
      depends-ms = unit.requires;

      # pulled in through `default` (waits-for) rather than `boot` (depends-on), so that a
      # unit which nothing else requires is still started without becoming a hard dependency
      # of the root service. hard would mean one failing leaf fails the entire boot, and that
      # no single unit could be stopped while the system runs. the graph's own edges carry
      # every requirement that actually exists; the root should add none of its own.
      default = true;
    }
    // lib.optionalAttrs (commandOf unit != null) { command = commandOf unit; }
    // lib.optionalAttrs (unit.user != null) { run-as = unit.user; }
    // lib.optionalAttrs (unit.environment != { }) { environment = unit.environment; }
    // lib.optionalAttrs (kindOf unit == "service" && readinessOf unit == "pidfile") {
      pid-file = (variantOf unit).readiness.pidfile.file;
    }
    // lib.optionalAttrs (unit.startTimeout != null) { start-timeout = unit.startTimeout; }
    // lib.optionalAttrs (unit.stopTimeout != null) { stop-timeout = unit.stopTimeout; }
    # the first trunk level depends on the latch, so the latch is started before anything
    # else and therefore stopped after everything else - which is what makes it mean
    # "every unit before me has stopped"
    // lib.optionalAttrs (name == lib.head trunk.levels && latchName != null) {
      depends-on = [ latchName ];
    };

  mkShutdownSide =
    unit:
    {
      type = "scripted";
      command = true';
      depends-on = successorOf unit.name;
      default = true;

      # the latch brackets the whole system: started first, stopped last. dinit documents
      # kill-all-on-stop for exactly this position, so shutdown work is not obstructed by
      # orphaned processes still holding filesystems open.
      options = lib.optionals (unit.name == latchName) [ "kill-all-on-stop" ];
    }
    // lib.optionalAttrs (commandOf unit != null) { stop-command = commandOf unit; }
    // lib.optionalAttrs (unit.user != null) { run-as = unit.user; }
    // lib.optionalAttrs (unit.stopTimeout != null) { stop-timeout = unit.stopTimeout; };
in
{
  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "dinit" ];
    };
  };

  config = lib.mkIf (cfg.backend == "dinit") {
    providers.services.supportedFeatures = {
      startTimeout = true;
      stopTimeout = true;

      # both native: `internal` services and `depends-ms` respectively
      nativeAnchors = true;
      nativeStartOnlyEdges = true;
    };

    dinit.services =
      lib.mapAttrs mkBootSide (lib.filterAttrs (n: u: !(onShutdownSide n u)) enabled)
      // lib.listToAttrs (map (unit: lib.nameValuePair unit.name (mkShutdownSide unit)) shutdownOrdered);

    # dinit's service files are a strict key/value format with no room for opaque metadata, so
    # each unit's fingerprint is written beside them instead. `list` reads them back.
    environment.etc = lib.mapAttrs' (
      name: fp: lib.nameValuePair "dinit-fingerprints/${name}" { text = fp; }
    ) cfg.switch.fingerprints;

    # unlike finit, dinit does not reconcile from its own configuration - which is why this
    # branch carries a bespoke python reconciler at all. so it gives the engine a real `list`,
    # and the engine's diff does the work the python script was written to do.
    providers.services.switch = {
      # `dinitctl list` reports every *loaded* service, started or not, so its output alone
      # would keep reporting a unit that has been stopped - and the engine would then see
      # nothing to reconcile. state is checked explicitly per unit rather than by parsing the
      # status glyphs in the list output, which are easy to misread and undocumented as an
      # interface.
      list = pkgs.writeShellScript "dinit-list" ''
        ${lib.getExe' config.dinit.package "dinitctl"} list 2>/dev/null |
          ${lib.getExe' pkgs.gnused "sed"} -n 's/^\[[^]]*\][[:space:]]*\([^[:space:]]*\).*/\1/p' |
          while read -r unit; do
            case "$unit" in boot|default) continue ;; esac

            fp="/etc/dinit-fingerprints/$unit"
            [ -e "$fp" ] || continue

            ${lib.getExe' config.dinit.package "dinitctl"} status "$unit" 2>/dev/null |
              ${lib.getExe' pkgs.gnugrep "grep"} -q 'State: STARTED' || continue

            printf '%s\t%s\n' "$unit" "$(cat "$fp")"
          done
      '';

      activate = pkgs.writeShellScript "dinit-activate" ''
        while read -r unit; do
          # pick up a changed definition before starting; harmless when it is unchanged
          ${lib.getExe' config.dinit.package "dinitctl"} reload "$unit" >/dev/null 2>&1 || true
          ${lib.getExe' config.dinit.package "dinitctl"} start "$unit" || echo "start $unit failed" >&2
        done
      '';

      deactivate = pkgs.writeShellScript "dinit-deactivate" ''
        while read -r unit; do
          # a unit reachable from the root cannot simply be stopped, so detach it first
          ${lib.getExe' config.dinit.package "dinitctl"} rm-dep need boot "$unit" >/dev/null 2>&1 || true
          ${lib.getExe' config.dinit.package "dinitctl"} rm-dep waits-for default "$unit" >/dev/null 2>&1 || true
          ${lib.getExe' config.dinit.package "dinitctl"} stop "$unit" || echo "stop $unit failed" >&2
          ${lib.getExe' config.dinit.package "dinitctl"} unload "$unit" >/dev/null 2>&1 || true
          rm -f "/etc/dinit.d/boot.d/$unit" "/etc/dinit.d/default.d/$unit"
        done
      '';
    };
  };
}
