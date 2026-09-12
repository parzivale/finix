{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;

  # `depends-ms` is a milestone dependency - the named service must start successfully once,
  # and may stop afterwards without affecting this one - which is exactly an edge that gates
  # starting and nothing else. the finit backend has to fake it.
  #
  # An anchor is a scripted unit running `true` rather than dinit.s own process-less
  # `internal`, which it could use. An anchor means the same thing on every backend and there
  # is no reason for it to behave differently on this one: `internal` has its own rules about
  # stopping and restarting, and a trunk level built out of it would not be the same object as
  # the trunk level next door. The cost is one `true` per level, at the moment it is reached.
  type = {
    anchor = "scripted";
    oneshot = "scripted";
  };

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};
  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);

  readinessLib = import ../../providers/services/readiness.nix { inherit pkgs lib; };

  waitKindOf =
    unit:
    if kindOf unit == "service" && readinessOf unit == "waitFor" then
      lib.head (lib.attrNames (variantOf unit).readiness.waitFor)
    else
      null;

  # dinit observes a forking daemon itself, through bgprocess and the pid file it names. The
  # other waitFor kinds it cannot observe at all - there is no "ready when this socket answers"
  # in its vocabulary - so those get a scripted unit alongside which does the waiting, and the
  # edges into them are pointed at that instead. Same shape as finit's companion, except finit
  # already had one for every unit and this is only made where it is needed.
  needsWaitUnit = unit: waitKindOf unit != null && waitKindOf unit != "pidfile";
  waitNameOf = name: "${name}-ready";

  # an edge naming a unit which has a wait unit means the wait, not the service: the service is
  # up as soon as it is running, which is the thing the wait exists because it is not enough.
  edgeTo = dep: if (enabled ? ${dep}) && needsWaitUnit enabled.${dep} then waitNameOf dep else dep;

  typeOf =
    unit:
    if kindOf unit != "service" then
      type.${kindOf unit}
    else if waitKindOf unit == "pidfile" then
      "bgprocess"
    else
      "process";

  commandOf = unit: (variantOf unit).command or null;

  indexOf =
    name:
    lib.findFirst (i: i != null) null (lib.imap0 (i: l: if l == name then i else null) trunk.levels);

  latchIndex = indexOf trunk.latch;

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
      depends-ms = map edgeTo unit.requires;

      # pulled in through `default` (waits-for) rather than `boot` (depends-on), so that a
      # unit which nothing else requires is still started without becoming a hard dependency
      # of the root service. hard would mean one failing leaf fails the entire boot, and that
      # no single unit could be stopped while the system runs. the graph's own edges carry
      # every requirement that actually exists; the root should add none of its own.
      default = true;
    }
    // lib.optionalAttrs (commandOf unit != null) { command = commandOf unit; }

    # an anchor has no command of its own, and a scripted unit without one is not a unit. The
    # `true` is the whole of it: reached, therefore started.
    // lib.optionalAttrs (kindOf unit == "anchor") { command = true'; }

    // lib.optionalAttrs (unit.user != null) { run-as = unit.user; }
    // lib.optionalAttrs (unit.environment != { }) { environment = unit.environment; }
    // lib.optionalAttrs (waitKindOf unit == "pidfile") {
      pid-file = (variantOf unit).readiness.waitFor.pidfile.file;
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

  # ---- the user role ----------------------------------------------------------------
  #
  # Reached when providers.services.user.backend names dinit and the system supervisor is
  # something else. The system supervisor then runs one dinit per user, and that dinit owns
  # the user's tree; the two cannot observe each other's state, which is why the contract
  # refuses an edge leaving a user's tree in this case.
  #
  # Nothing here is specific to what the system supervisor happens to be: the per-user trees
  # are written out, and one ordinary unit per user is added to the system graph to run them,
  # so finit - or anything else - runs a command it does not have to understand.
  settingsFormat = import ./format.nix { inherit pkgs lib; };

  userDir = user: "dinit-user/${user}";
  socketDir = user: "/run/user-services/${user}";

  # each user's tree, plus a root for their instance to start. the root only waits for its
  # members, so one failing unit does not fail that user's whole session - the same soft pull
  # the system role uses.
  userFiles =
    user: u:
    lib.mapAttrs' (
      name: unit:
      lib.nameValuePair "${userDir user}/${name}" {
        # the same bookkeeping keys the system tree strips: they are ours, not dinit's, and
        # it exits rather than ignoring one it does not recognise
        source = settingsFormat.generate name (
          builtins.removeAttrs (mkBootSide name unit) [
            "enable"
            "environment"
            "path"
            "boot"
            "default"
          ]
        );
      }
    ) u.units
    // {
      "${userDir user}/boot".source = settingsFormat.generate "boot" {
        type = "internal";
        waits-for = lib.attrNames u.units;
      };
    };

  # the unit the system supervisor runs. it is an ordinary unit of the system graph, so it may
  # depend on system units - and everything in that user's tree sits transitively behind
  # whatever it depends on. that is the only cross-scope dependency this rule offers.
  supervisorUnit = user: {
    description = "dinit service manager for ${user}";
    user = user;
    # the socket directory must exist and be hers before her instance can open a socket in it
    requires = [
      "multi-user"
      "user-services-dir--${user}"
    ];
    type.service.command = "${config.dinit.package}/bin/dinit --user -d /etc/${userDir user} -p ${socketDir user}/dinitctl boot";
  };

in
{
  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "dinit" ];
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.backend == "dinit") {
      providers.services.supportedFeatures = {
        startTimeout = true;
        stopTimeout = true;

        # dinit does have a readiness protocol, through `readiness-notification`, but this
        # backend does not use it yet - so `notify` and `s6` are refused rather than mapped
        # onto a plain `process`, which would call a unit ready the moment it was spawned and
        # start everything behind it too early. Every waitFor kind is available: `pidfile`
        # through bgprocess, which is dinit watching the fork itself, the rest through a
        # wait unit.
        readiness = [
          "fork"
          "waitFor.socket"
          "waitFor.pidfile"
          "waitFor.path"
          "waitFor.check"
        ];

        user = true;

        # `run-as` names a user and not a group, and dinit has no per-service PATH
        group = false;
        path = false;
      };

      # dinit is its own init, so this is what the kernel runs.
      #
      # The wrapper is here because boot.init is a single executable the toplevel symlinks,
      # with nowhere to put arguments. Neither argument can be a store path: the control
      # socket has to live on a writable filesystem, and the service directory has to stay a
      # stable name so that a switch can change what it contains without restarting PID 1.
      # Booted against /nix/store/...-dinit.d, this dinit would go on reading the generation
      # the machine booted with however many times the engine reloaded it.
      #
      # /run is already a tmpfs by the time this runs - the initrd mounts it - so there is
      # nothing to create first.
      providers.services.initExecutable = pkgs.writeShellScript "dinit-init" ''
        # /etc/dinit.d is one of the things activation creates, so this has to come first -
        # without it dinit starts correctly and then reports "could not find service
        # description", which looks like a dinit problem and is not one
        ${cfg.activationScript}

        exec ${config.dinit.package}/bin/dinit -p /run/dinitctl -d /etc/dinit.d boot
      '';

      # dinit ships all three, and they reach it over the control socket - /run/dinitctl, which
      # is both dinit's own default and what initExecutable above asks for, so they need no
      # argument to find it.
      providers.services.shutdownCommands = {
        poweroff = "${config.dinit.package}/bin/poweroff";
        reboot = "${config.dinit.package}/bin/reboot";
        halt = "${config.dinit.package}/bin/halt";
      };

      dinit.services =
        lib.mapAttrs mkBootSide (lib.filterAttrs (n: u: !(onShutdownSide n u)) enabled)
        // lib.listToAttrs (map (unit: lib.nameValuePair unit.name (mkShutdownSide unit)) shutdownOrdered)

        # one per unit whose readiness dinit cannot observe: a scripted unit which blocks until
        # the thing is live and then completes, which is dinit's own way of saying "started".
        # Edges into the service were pointed here by edgeTo.
        // lib.mapAttrs' (
          name: unit:
          lib.nameValuePair (waitNameOf name) {
            description = "${name} is ready";
            type = "scripted";
            command = readinessLib.scriptFor name (variantOf unit).readiness;
            depends-ms = [ name ];
            default = true;
          }
        ) (lib.filterAttrs (n: u: !(onShutdownSide n u) && needsWaitUnit u) enabled);

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
    })

    # dinit as the per-user supervisor, with something else running the system
    (lib.mkIf (cfg.user.backend == "dinit" && cfg.user.backend != cfg.backend) {
      # dinit has a per-user mode, so it can serve this role
      providers.services.user.supported = true;

      environment.etc = lib.concatMapAttrs userFiles cfg.users;

      # the socket directory has to exist and belong to the user before their instance can
      # open a control socket in it
      providers.services.units =
        lib.mapAttrs' (
          user: _:
          lib.nameValuePair "user-services-dir--${user}" {
            description = "control socket directory for ${user}";
            requires = [ "sysinit" ];
            type.oneshot.command = pkgs.writeShellScript "user-services-dir-${user}" ''
              ${lib.getExe' pkgs.coreutils "mkdir"} -p ${socketDir user}
              ${lib.getExe' pkgs.coreutils "chown"} ${user} ${socketDir user}
            '';
          }
        ) cfg.users
        // lib.mapAttrs' (
          user: _: lib.nameValuePair "user-services--${user}" (supervisorUnit user)
        ) cfg.users;
    })
  ];
}
