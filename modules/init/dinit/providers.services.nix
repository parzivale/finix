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

  readinessLib = import ../../providers/services/readiness.nix {
    inherit pkgs lib;
    inherit (cfg) readinessPollInterval;
  };
  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  # where the running generation's fingerprints live, and the store copy /run is seeded from at
  # boot. Not /etc: activation rewrites that before the engine is ever asked what is running.
  runFingerprints = "/run/dinit-fingerprints";

  fingerprintDir = pkgs.runCommand "dinit-fingerprints" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (
        name: fp: "printf '%s' ${lib.escapeShellArg fp} > $out/${name}\n"
      ) cfg.switch.fingerprints
    )
  );

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
  # an edge, resolved against the scope the unit lives in.
  #
  # Scoped rather than always `enabled`, because a user's tree is a graph of its own: its units
  # are not in `enabled` at all, so a lookup there found nothing and every edge was left pointing
  # at the service instead of at its readiness companion. Which is silent - dinit calls a
  # `process` started once it has forked - so `wireplumber` began the moment `pipewire` existed
  # rather than when it would answer, reinstating exactly the race `waitFor.socket` was chosen to
  # close.
  edgeIn = scope: dep: if (scope ? ${dep}) && needsWaitUnit scope.${dep} then waitNameOf dep else dep;

  edgeTo = edgeIn enabled;

  typeOf =
    unit:
    if kindOf unit != "service" then
      type.${kindOf unit}
    else if waitKindOf unit == "pidfile" then
      "bgprocess"
    else
      "process";

  # dinit has no per-service PATH, so one is scripted in rather than declared unsupported.
  #
  # A capability the contract has and one implementation lacks is better emulated than refused:
  # refusing it means every module which wants a PATH writes this same wrapper by hand, once
  # per module, and gets it subtly different each time - and a unit which sets `path` then
  # works on three backends and quietly does not on the fourth.
  #
  # `"$@"` because whatever the implementation appends to a command - a readiness descriptor -
  # is appended to this wrapper, so it has to be passed on rather than swallowed.
  withPath =
    name: unit: command:
    if unit.path == [ ] then
      command
    else
      "${pkgs.writeShellScript "${name}-with-path" ''
        export PATH=${lib.makeBinPath unit.path}:$PATH
        exec ${command} "$@"
      ''}";

  commandOf =
    name: unit:
    if (variantOf unit) ? command then withPath name unit (variantOf unit).command else null;

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

  # the whole shutdown side as one script, in trunk order.
  #
  # The chain below is correct on paper - each unit depends on the one after it, so stopping
  # dependents first walks the trunk forwards - and dinit does not honour it during a full
  # shutdown. With `then-down` attached to a later level than `first-down`, dinit ran
  # `then-down`'s stop-command first, and it reported that the earlier step had not run.
  #
  # So ordering becomes the shell's job, which is a guarantee that does hold. This is the same
  # conclusion the finit backend reached, for the same reason.
  #
  # It hangs off the latch, which is the one service guaranteed to stop after the boot side:
  # the first trunk level depends on it, so everything reachable from the root stops first.
  shutdownScript = shutdownLib.scriptFor cfg;

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
    scope: name: unit:
    {
      type = typeOf unit;
      depends-ms = map (edgeIn scope) unit.requires;

      # pulled in through `default` (waits-for) rather than `boot` (depends-on), so that a
      # unit which nothing else requires is still started without becoming a hard dependency
      # of the root service. hard would mean one failing leaf fails the entire boot, and that
      # no single unit could be stopped while the system runs. the graph's own edges carry
      # every requirement that actually exists; the root should add none of its own.
      default = true;
    }
    // lib.optionalAttrs (commandOf name unit != null) { command = commandOf name unit; }

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
    # one stop-command for the whole shutdown side, on the latch. Per-unit stop-commands left
    # the order to dinit, which does not keep it - see shutdownScript.
    # and on the script existing: the levels at and after the latch are themselves shutdown-side
    # units, so a machine whose shutdown side is only those anchors has nothing to run
    // lib.optionalAttrs (unit.name == latchName && shutdownScript != null) {
      stop-command = "${shutdownScript}";
    }
    // lib.optionalAttrs (unit.stopTimeout != null) { stop-timeout = unit.stopTimeout; };

  # ---- the user role ----------------------------------------------------------------
  #
  # Reached when providers.services.user.backend names dinit, whatever is running the system -
  # including dinit. A user's tree is supervised by an instance started by their session, so it is
  # never the same instance as PID 1 even when it is the same implementation: PID 1 began before
  # the session and outlives it, and could hold neither its environment nor its lifetime.
  #
  # The two instances cannot observe each other's state, which is why the contract refuses an edge
  # leaving a user's tree.
  #
  # Nothing here is specific to what the system supervisor happens to be: the per-user trees are
  # written out and the session starts one, so finit - or anything else - runs a command it does
  # not have to understand.
  settingsFormat = import ./format.nix { inherit pkgs lib; };

  # the same one `dinit.services` uses for its own `env-file`. `NAME=value`, one per line, which
  # is what dinit reads - not the quoted shell assignments `keyValue` writes by default.
  envFormat = pkgs.formats.keyValue {
    mkKeyValue = k: v: "${k}=${toString v}";
  };

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
          builtins.removeAttrs (mkBootSide u.units name unit) [
            "enable"
            "environment"
            "path"
            "boot"
            "default"
          ]

          # `environment` is one of those keys, and turning it into the file dinit does read is
          # what the system tree's settings submodule does on the way past - which this does not
          # go through, so it has to do it here. Left out, a unit's environment was accepted,
          # stripped, and never reached the process: `ALSA_CONFIG_UCM2` naming a machine's mixer
          # topology was set on pipewire and wireplumber and arrived at neither.
          // lib.optionalAttrs (unit.environment != { }) {
            env-file = envFormat.generate "${user}-${name}.env" unit.environment;
          }

          # somewhere for the unit's own account of itself to go.
          #
          # dinit's default log type is `none` - output discarded - and nothing was setting
          # otherwise, so a user unit that failed said only that it had. A session daemon dying
          # with `exit status: 255` and no line anywhere explaining it is the whole cost: the tree
          # is the part of the machine least visible from a terminal and it was the only part with
          # no log at all.
          #
          # `buffer` rather than `file`: a file wants a path the user can write, which means
          # inventing one per user and creating it before the tree starts, and its contents would
          # then outlive the session that produced them. A buffer needs neither - it lives as long
          # as the instance does, which is as long as the session does, and `dinitctl catlog
          # <unit>` reads it back.
          #
          # This is the same thing `log = true` does for the system tree on finit, arrived at
          # differently because dinit's route to it is a per-service property rather than a global.
          // {
            log-type = "buffer";
            # 4k is not many lines, and the lines worth having are the ones from a daemon that is
            # about to exit - which are the first ones out, so the buffer has to be large enough
            # not to have wrapped past them by the time anyone looks.
            log-buffer-size = 65536;
          }
        );
      }
    ) u.units

    # the readiness companions, one per unit whose readiness dinit cannot observe for itself.
    #
    # The same units the system tree gets and for the same reason: dinit calls a `process`
    # started once it has forked, so without these a dependent begins when the service exists
    # rather than when it answers. `edgeIn u.units` above points this user's edges at them.
    // lib.mapAttrs' (
      name: unit:
      lib.nameValuePair "${userDir user}/${waitNameOf name}" {
        source = settingsFormat.generate (waitNameOf name) {
          type = "scripted";
          command = "${readinessLib.scriptFor name (variantOf unit).readiness}";
          depends-ms = [ name ];
        };
      }
    ) (lib.filterAttrs (_: needsWaitUnit) u.units)

    // {
      # everything in the tree, so that starting `boot` starts all of it - and the readiness
      # companions too, since a unit nothing else waits for would otherwise never have its
      # readiness observed at all.
      "${userDir user}/boot".source = settingsFormat.generate "boot" {
        type = "internal";
        waits-for =
          lib.attrNames u.units
          ++ map waitNameOf (lib.attrNames (lib.filterAttrs (_: needsWaitUnit) u.units));
      };

      # the head of the trunk, in this user's namespace.
      #
      # `requires` defaults to the head of the tree a unit is in, and the unit type is shared with
      # the system's, so a user unit which said nothing about ordering named this. It is an anchor
      # there and an anchor here: something to attach to, which is reached immediately because it
      # waits for nothing.
      "${userDir user}/${lib.head cfg.trunk.levels}".source =
        settingsFormat.generate (lib.head cfg.trunk.levels)
          {
            type = "internal";
          };
    };

in
{
  # enabling an implementation is what selects it: this names itself into the contract
  # below, the same way every other providers implementation does when it is enabled.
  options.dinit.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether to boot dinit as PID 1, supervising the system with it.

      Enabling it points {option}`providers.services.backend` at `dinit`, which is what
      actually selects an implementation - so this is a default, and a machine naming a
      backend directly still wins.
    '';
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "dinit" ];
    };
  };

  config = lib.mkMerge [
    # this module supplies an implementation for `providers.services`
    (lib.mkIf config.dinit.enable {
      providers.services.backend = lib.mkDefault "dinit";
    })

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
        # dinit has no per-service PATH of its own, but `withPath` above scripts one in, so a
        # unit which asks for one gets it here too
        path = true;
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

        # the generation about to be started, recorded as the running one. This is in the init
        # rather than in activation because activation runs on every switch too, and rewriting
        # these then would tell the next `list` that whatever is running was already what is
        # being switched into.
        ${lib.getExe' pkgs.coreutils "rm"} -rf ${runFingerprints}
        ${lib.getExe' pkgs.coreutils "cp"} -rL ${fingerprintDir} ${runFingerprints}
        ${lib.getExe' pkgs.coreutils "chmod"} -R u+w ${runFingerprints}

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
        lib.mapAttrs (mkBootSide enabled) (lib.filterAttrs (n: u: !(onShutdownSide n u)) enabled)
        // lib.listToAttrs (map (unit: lib.nameValuePair unit.name (mkShutdownSide unit)) shutdownOrdered)

        # one per unit whose readiness dinit cannot observe: a scripted unit which blocks until
        # the thing is live and then completes, which is dinit's own way of saying "started".
        # Edges into the service were pointed here by edgeTo.
        // lib.mapAttrs' (
          name: unit:
          lib.nameValuePair (waitNameOf name) {
            # no description: a dinit service file has no such field, and dinit.services has no
            # option for one
            type = "scripted";
            # interpolated, not passed through: a dinit service file is key/value text, so the
            # command is a string. scriptFor hands back a derivation for every waitFor kind bar
            # `check`, where it is the command the configuration supplied.
            command = "${readinessLib.scriptFor name (variantOf unit).readiness}";
            depends-ms = [ name ];
            default = true;
          }
        ) (lib.filterAttrs (n: u: !(onShutdownSide n u) && needsWaitUnit u) enabled);

      # dinit's service files are a strict key/value format with no room for opaque metadata, so
      # each unit's fingerprint is written beside them instead. `list` reads them back.
      # nothing in /etc. A fingerprint has to say what the *running* generation was built from,
      # and switch-to-configuration runs activation before it runs the engine - so by the time
      # `list` is asked, /etc has already been replaced by the generation being switched into.
      # A removed unit's file is gone, so `list` skipped it and the engine never learned it was
      # running; a changed unit's file already held the new value, so it compared equal to
      # itself and was never restarted. See fingerprintDir, which /run is seeded from at boot.

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

              ${lib.getExe' config.dinit.package "dinitctl"} status "$unit" 2>/dev/null |
                ${lib.getExe' pkgs.gnugrep "grep"} -q 'State: STARTED' || continue

              # dinit decides what is running; the fingerprint only says which definition it
              # was started from, which no supervisor can be asked - dinitctl reports state and
              # pid, never the command line or dependencies behind them.
              #
              # So a missing record must not remove the unit from the list. One started by hand
              # has none, and skipping it makes it invisible to the engine: never stopped when
              # the incoming tree drops it, and "started" as a no-op when it does not. Reported
              # as `unknown`, which cannot equal a real fingerprint, the pair differs and the
              # unit is reconciled - stopped if it is gone, restarted if it remains.
              fp="${runFingerprints}/$unit"
              if [ -e "$fp" ]; then
                printf '%s\t%s\n' "$unit" "$(cat "$fp")"
              else
                printf '%s\tunknown\n' "$unit"
              fi
            done
        '';

        activate = pkgs.writeShellScript "dinit-activate" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

          while read -r unit; do
            # pick up a changed definition before starting; harmless when it is unchanged
            ${lib.getExe' config.dinit.package "dinitctl"} reload "$unit" >/dev/null 2>&1 || true
            ${lib.getExe' config.dinit.package "dinitctl"} start "$unit" || echo "start $unit failed" >&2

            # what is now running, recorded where the next switch will look. Written after the
            # start rather than before, so a unit which failed to start is not claimed as this
            # generation's.
            if [ -e ${fingerprintDir}/"$unit" ]; then
              mkdir -p ${runFingerprints}
              cp -f ${fingerprintDir}/"$unit" ${runFingerprints}/"$unit"
            fi
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

            # no longer running, so no longer this generation's
            rm -f ${runFingerprints}/"$unit"
          done
        '';
      };
    })

    # dinit supervising a user's tree, started by their session
    #
    # not gated on the system's backend being something else. dinit as PID 1 and a dinit per
    # session is two processes, and that is correct rather than redundant: PID 1 started before
    # any session existed and will outlive it, so it can have neither the session's environment
    # nor its lifetime. systemd does the same thing for the same reason, one `systemd --user` per
    # user beside PID 1 - and pays for the shared-across-sessions part with
    # `import-environment`, which per-session starting is what avoids.
    (lib.mkIf (cfg.user.backend == "dinit") {
      providers.services.user.manager.supervisor.command =
        user:
        "${config.dinit.package}/bin/dinit --user -d /etc/${userDir user} -p ${socketDir user}/dinitctl boot";

      environment.etc = lib.concatMapAttrs userFiles cfg.users;

      # `-d` above, rather than dinit's own user-mode search path. the default list
      # (`$XDG_CONFIG_HOME/dinit.d`, `$HOME/.config/dinit.d`, `/etc/dinit.d/user`, ...) has one
      # shared directory per system, not one per user, so two users' trees would be the same
      # tree. passing a directory suppresses the defaults, which is also what keeps a stray
      # description in a home directory out of a generated tree.
      #
      # the socket directory has to exist and belong to the user before their instance can open a
      # control socket in it - and it is still boot work, because it is the one part of this that
      # needs root and so cannot happen inside the session.
      providers.services.units = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "user-services-dir--${user}" {
          description = "control socket directory for ${user}";
          requires = [ "sysinit" ];
          type.oneshot.command = pkgs.writeShellScript "user-services-dir-${user}" ''
            ${lib.getExe' pkgs.coreutils "mkdir"} -p ${socketDir user}
            ${lib.getExe' pkgs.coreutils "chown"} ${user} ${socketDir user}
          '';
        }
      ) cfg.users;
    })
  ];
}
