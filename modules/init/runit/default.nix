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

  readinessLib = import ../../providers/services/readiness.nix { inherit pkgs lib; };

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

  # `sv` resolves a bare service name through SVDIR, which defaults somewhere else entirely,
  # so every call names the directory outright.
  scanDir = "/run/service";

  latchDir = "/run/providers-services";
  latch = name: "${latchDir}/${name}.ready";

  waitFor =
    unit:
    lib.concatMapStrings (dep: ''
      while [ ! -e ${latch dep} ]; do ${sleep} 0.1; done
    '') unit.requires;

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
    name: unit:
    let
      kind = kindOf unit;
      v = variantOf unit;
    in
    pkgs.writeShellScript "${name}-run" (
      ''
        exec 2>&1
        ${lib.optionalString (unit.path != [ ]) "export PATH=${lib.makeBinPath unit.path}:\$PATH"}
        ${mkdir} -p ${latchDir}
        ${waitFor unit}
      ''
      + (
        if kind == "anchor" then
          ''
            ${touch} ${latch name}
            ${park}
          ''
        else if kind == "oneshot" then
          ''
            ${asUser unit}${v.command}
            ${touch} ${latch name}
            ${park}
          ''
        else if readinessOf unit == "waitFor" then
          ''
            # nothing to latch from once the daemon has been exec'd into, so the wait runs
            # alongside it and latches when whatever it is waiting for is live. runit observes
            # nothing itself - not even a forking daemon - so every waitFor kind is this.
            ( ${readinessLib.scriptFor name v.readiness}
              ${touch} ${latch name} ) &
            exec ${asUser unit}${v.command}
          ''
        else
          ''
            # `fork` readiness: up the moment it is running, which is what runit itself means
            # by a service being up. `notify` and `s6` never reach here - the contract refuses
            # them against this backend.
            ${touch} ${latch name}
            exec ${asUser unit}${v.command}
          ''
      )
    );

  # the service directories, assembled in the store and copied somewhere writable at boot -
  # runsv needs to create `supervise` inside each one.
  serviceDir = pkgs.runCommand "runit-services" { } ''
    mkdir -p $out
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: unit: ''
        mkdir -p $out/${name}
        ln -s ${runScript name unit} $out/${name}/run
        printf '%s' ${lib.escapeShellArg cfg.switch.fingerprints.${name}} > $out/${name}/fingerprint
      '') enabled
    )}
  '';

  sv = lib.getExe' pkgs.runit "sv";
in
{
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

  config = lib.mkIf (cfg.backend == "runit") {
    providers.services.runit.serviceDir = serviceDir;

    providers.services.supportedFeatures = {
      # runit bounds neither: `sv -w` waits on the caller's side rather than the service's,
      # and stopping is SIGTERM then SIGKILL on a fixed schedule
      startTimeout = false;
      stopTimeout = false;

      # runit speaks neither protocol - it knows only that a process is running - so both are
      # refused by the contract rather than silently treated as `fork`. Every waitFor kind is
      # available, polled from inside the run script.
      readiness = [ ];

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
    providers.services.initExecutable = pkgs.writeShellScript "runit-init" ''
      ${cfg.activationScript}
      exec ${pkgs.runit}/bin/runit-init
    '';

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
        mkdir -p ${latchDir}
        rm -rf ${scanDir}
        cp -rL ${serviceDir} ${scanDir}
        chmod -R u+w ${scanDir}
      '';

      # stage 2. runsvdir execs `runsv` by name for each service directory, so it needs runit
      # on PATH - which nothing else arranges, and this does for itself.
      "runit/2".source = pkgs.writeShellScript "runit-stage-2" ''
        export PATH=${lib.makeBinPath [ pkgs.runit ]}:$PATH
        exec ${lib.getExe' pkgs.runit "runsvdir"} ${scanDir}
      '';

      # stage 3. runit has already stopped the supervisor by the time this runs; the contract's
      # shutdown-side units are the graph's business, not runit's.
      "runit/3".source = pkgs.writeShellScript "runit-stage-3" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
        echo "runit: shutting down"
      '';
    };

    providers.services.switch = {
      list = pkgs.writeShellScript "runit-list" ''
        for dir in ${scanDir}/*; do
          [ -d "$dir" ] || continue
          unit=$(${lib.getExe' pkgs.coreutils "basename"} "$dir")
          [ -e "$dir/fingerprint" ] || continue
          ${sv} status "$dir" 2>/dev/null | ${lib.getExe' pkgs.gnugrep "grep"} -q '^run:' || continue
          printf '%s\t%s\n' "$unit" "$(cat "$dir/fingerprint")"
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
          if [ -d ${serviceDir}/"$unit" ]; then
            mkdir -p ${scanDir}/"$unit"

            cp -fL ${serviceDir}/"$unit"/run ${scanDir}/"$unit"/run
            cp -fL ${serviceDir}/"$unit"/fingerprint ${scanDir}/"$unit"/fingerprint
            chmod u+w ${scanDir}/"$unit"/run ${scanDir}/"$unit"/fingerprint

            # runsvdir rescans on its own schedule - every five seconds - so a directory which
            # has just appeared has no runsv behind it yet, and `sv start` on it fails rather
            # than waiting. This waits for the supervisor to notice instead of racing it.
            for _ in $(seq 1 100); do
              if [ -e ${scanDir}/"$unit"/supervise/ok ]; then
                break
              fi
              sleep 0.1
            done
          fi

          ${sv} start ${scanDir}/"$unit" || echo "start $unit failed" >&2
        done
      '';

      deactivate = pkgs.writeShellScript "runit-deactivate" ''
        while read -r unit; do
          ${sv} stop ${scanDir}/"$unit" || echo "stop $unit failed" >&2
          rm -f ${latchDir}/"$unit".ready
        done
      '';
    };
  };
}
