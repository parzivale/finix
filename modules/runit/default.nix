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
# every supportedFeatures flag here is false. it is the furthest the contract stretches.
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
            ${v.command}
            ${touch} ${latch name}
            ${park}
          ''
        else if readinessOf unit == "pidfile" then
          ''
            # nothing to latch from once the daemon has been exec'd into, so the wait runs
            # alongside it and latches when the pid file appears
            ( while [ ! -s ${v.readiness.pidfile.file} ]; do ${sleep} 0.1; done
              ${touch} ${latch name} ) &
            exec ${v.command}
          ''
        else
          ''
            # `fork` readiness: up the moment it is running, which is what runit itself means
            # by a service being up
            ${touch} ${latch name}
            exec ${v.command}
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

      # a process-less unit has to park on `sleep infinity`, and an edge has to be synthesised
      # out of latch files, because runit has no notion of either
      nativeAnchors = false;
      nativeStartOnlyEdges = false;
    };

    # runit can only tell that a process is running, or that a pid file appeared. it has no
    # readiness protocol at all, so a unit asking for one cannot be honoured rather than
    # silently downgraded.
    assertions = lib.mapAttrsToList (name: unit: {
      assertion =
        kindOf unit == "service"
        -> lib.elem (readinessOf unit) [
          "fork"
          "pidfile"
        ];
      message = ''
        providers.services.units.${name} reports readiness by ${readinessOf unit}, which runit
        cannot observe - it knows only whether a process is running, and whether a pid file
        has appeared. Use `fork` or `pidfile`, or gate dependants behind a oneshot which polls
        for whatever readiness actually means for this unit.
      '';
    }) (lib.filterAttrs (_: u: kindOf u == "service") enabled);

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
        while read -r unit; do
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
