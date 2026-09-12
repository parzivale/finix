# a providers.services implementation backed by s6-rc
#
# s6-rc is unlike the others in three ways, and each one exercises something the contract has
# not had to express before.
#
# its configuration is compiled, not read. a source tree is fed to `s6-rc-compile`, which
# produces a binary database, and the supervisor runs against that - so the artifact this
# backend produces is a built database in the store rather than files an init parses at boot.
#
# it speaks s6 readiness natively, through `notification-fd`, which finit only manages because
# finit happens to speak the protocol and dinit refuses outright. it has no notion of a pid
# file at all, so this is the first implementation whose readiness set is neither a prefix nor
# a superset of another's.
#
# and it has native down scripts, so shutdown work is an ordinary property of a unit rather
# than something to be reconstructed - finit needed a generated script and dinit needed an
# inverted chain of stop-commands.
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
  commandOf = unit: (variantOf unit).command or null;

  s6rc = pkgs.s6-rc;

  # s6-rc dependencies order the change operations and nothing else: a longrun which dies is
  # restarted by its supervisor, and nothing depending on it is touched. that is the contract's
  # start-only edge without any emulation, which only dinit has otherwise managed.
  #
  # That holds while the machine runs. It does not hold across a database update, and the
  # difference is worth writing down: s6-rc-update restarts a service which "has a dependency
  # to [...] a new service that did not previously exist", so adding a unit low in the trunk
  # restarts everything attached to the levels above it. The contract's model defines how
  # services are brought up, not that a switch moves the same set on every implementation, so
  # this is a property of s6-rc rather than a contract violation - but a machine switching
  # here bounces more than one switching on finit, dinit or runit does.
  dependencies = unit: lib.concatMapStrings (dep: "${dep}\n") unit.requires;

  readinessLib = import ../../providers/services/readiness.nix { inherit pkgs lib; };
  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  # the `everything` bundle is brought up at boot, and s6-rc has no notion of a unit which is
  # in the database but not to be started yet. A shutdown-side unit compiled into it therefore
  # ran during boot, which is not late but wrong - so the database is built from the boot side
  # alone, and the shutdown side is run from rc.shutdown instead.
  bootSide = lib.filterAttrs (name: unit: !(shutdownLib.onShutdownSide cfg.trunk name unit)) enabled;

  shutdownScript = shutdownLib.scriptFor cfg;

  # what the engine may be told to start and stop, and what `list` may report: the boot side,
  # minus the anchors. An anchor is a bundle here, and a bundle is a compile-time name for a
  # set - it has no state, so s6-rc will neither list it nor change it.
  atomic = lib.filterAttrs (_: unit: kindOf unit != "anchor") bootSide;

  # everything in the generation which s6-rc has no state for: the shutdown side, which is not
  # in the database because s6-rc starts what it knows about at boot, and the anchors, which
  # are bundles.
  #
  # `list` reports them with the fingerprint this generation was built from. They are not
  # running - an anchor never is, and the shutdown side only runs on the way down - but neither
  # can the engine start them. Reporting nothing would leave them in the incoming tree and out
  # of the current one, so every switch would resolve to "start the shutdown side and every
  # level", forever. Reported as already matching, the engine finds nothing to do.
  unmanaged = lib.filterAttrs (name: _: !(atomic ? ${name})) enabled;

  reportUnmanaged = lib.concatStrings (
    lib.mapAttrsToList (
      name: _: "printf '%s\\t%s\\n' ${name} ${lib.escapeShellArg cfg.switch.fingerprints.${name}}\n"
    ) unmanaged
  );

  # the engine reconciles the whole incoming tree, which includes the shutdown side and the
  # anchors - neither of which s6-rc can be asked about. The shutdown side is deliberately not
  # in this database, because s6-rc starts everything it knows about at boot; the anchors are
  # bundles. Naming either fails the entire change, taking the units which do exist down with
  # it. Reads unit names on stdin and leaves the survivors in $units.
  knownFilter = ''
    known=" ${lib.concatStringsSep " " (lib.attrNames atomic)} "
    units=""
    while read -r unit; do
      case "$known" in
        *" $unit "*) units="$units $unit" ;;
      esac
    done
  '';

  # null unless this unit is a service with a waitFor readiness
  waitScript =
    name: unit:
    if kindOf unit == "service" then readinessLib.scriptFor name (variantOf unit).readiness else null;

  runScript =
    name: unit:
    pkgs.writeShellScript "${name}-run" ''
      ${lib.optionalString (unit.path != [ ]) "export PATH=${lib.makeBinPath unit.path}:$PATH"}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") unit.environment
      )}
      ${
        lib.optionalString (waitScript name unit != null) ''
          # s6 speaks one readiness protocol, so a waitFor is turned into it: the daemon starts
          # here, the wait runs beside it, and the notification s6 is already listening for is
          # written when whatever it waits on is live. Dependants then need nothing special.
          (
            ${waitScript name unit}
            printf '\n' >&3
          ) &
        ''
      }exec ${
        lib.optionalString (unit.user != null) "${lib.getExe' pkgs.s6 "s6-setuidgid"} ${unit.user} "
      }${commandOf unit}
    '';

  # one directory per unit, in the source layout s6-rc-compile expects
  unitDir =
    name: unit:
    let
      kind = kindOf unit;
    in
    if kind == "anchor" then
      # an anchor is a name for a set rather than something which runs, and that is precisely
      # what an s6-rc bundle is. As a oneshot running `true` it had state, and s6-rc-update
      # then felt obliged to reconcile it: a trunk level's edges change whenever any unit is
      # added or removed anywhere, so every switch found the level's definition changed,
      # restarted it, and - dependencies here being hard - brought down everything above it.
      # One added unit restarted the machine.
      #
      # A bundle has no state, so changing its contents restarts nothing. Depending on one is
      # depending on all of its members, which is exactly what "this level has been reached"
      # means. Bundles cannot have dependencies of their own, so what would have been the
      # anchor's `requires` becomes its contents - the same set, said the other way round.
      ''
        mkdir -p $out/source/${name}
        printf 'bundle\n' > $out/source/${name}/type
        printf '%s' ${lib.escapeShellArg (dependencies unit)} > $out/source/${name}/contents
      ''
    else
      ''
        mkdir -p $out/source/${name}
        printf '%s\n' ${if kind == "service" then "longrun" else "oneshot"} > $out/source/${name}/type
        printf '%s' ${lib.escapeShellArg (dependencies unit)} > $out/source/${name}/dependencies
      ''
      + (
        # a longrun's `run` is an executable the supervisor execs, but a oneshot's `up` is an
        # execline command line which s6-rc-compile reads as text - so one is linked in and the
        # other is written out. linking a binary in as `up` makes s6-rc try to parse an ELF
        # header as a command.
        if kind == "service" then
          ''
            ln -s ${runScript name unit} $out/source/${name}/run
          ''
          # `fork` means no notification at all: s6 calls it up once spawned. `s6` is the daemon
          # notifying for itself, and `waitFor` is the wrapper in the run script notifying on its
          # behalf - both arrive on the same descriptor, so both are declared the same way.
          +
            lib.optionalString
              (lib.elem (readinessOf unit) [
                "s6"
                "waitFor"
              ])
              ''
                printf '3\n' > $out/source/${name}/notification-fd
              ''
        else
          ''
            printf '%s\n' ${runScript name unit} > $out/source/${name}/up
          ''
      )
      + lib.optionalString (unit.startTimeout != null) ''
        printf '%d\n' ${toString (unit.startTimeout * 1000)} > $out/source/${name}/timeout-up
      ''
      + lib.optionalString (unit.stopTimeout != null) ''
        printf '%d\n' ${toString (unit.stopTimeout * 1000)} > $out/source/${name}/timeout-down
      '';

  # the whole point of this backend: the database is built here, not assembled at boot. a
  # configuration error is a build failure rather than something discovered on the machine.
  database = pkgs.runCommand "s6-rc-database" { nativeBuildInputs = [ s6rc ]; } ''
    mkdir -p $out
    ${lib.concatStrings (lib.mapAttrsToList unitDir bootSide)}

    mkdir -p $out/source/everything
    printf 'bundle\n' > $out/source/everything/type
    printf '%s' ${
      lib.escapeShellArg (lib.concatMapStrings (n: "${n}\n") (lib.attrNames bootSide))
    } > $out/source/everything/contents

    s6-rc-compile $out/db $out/source
  '';

  live = "/run/s6-rc";
  scanDir = "/run/service";

  # where the running generation's fingerprints live, and the store copy /run is seeded from at
  # boot. Not /etc: switch-to-configuration runs activation before it runs the engine, so /etc
  # already describes the generation being switched into by the time `list` is asked what is
  # running. A removed unit's file was gone, so the engine never learned it was running and
  # never stopped it; a changed unit's file already held the new value, so it compared equal to
  # itself and was never restarted.
  runFingerprints = "/run/s6-rc-fingerprints";

  fingerprintDir = pkgs.runCommand "s6-rc-fingerprints" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (
        name: fp: "printf '%s' ${lib.escapeShellArg fp} > $out/${name}\n"
      ) cfg.switch.fingerprints
    )
  );

  # ---- being an init, rather than merely supervising ---------------------------------------
  #
  # s6-svscan supervises and reaps, which is most of what PID 1 does, but not all of it: a
  # machine also has to be able to reboot, to handle Ctrl-Alt-Del, to catch the output of
  # things which log before a logger exists, and to bring services down in order on the way
  # out. s6-linux-init is the piece which does that, and it wraps s6-svscan rather than
  # replacing it.
  #
  # It is generated by s6-linux-init-maker, which bakes its own location into the scripts it
  # writes. That location is this derivation's output rather than /etc/s6-linux-init: the
  # kernel runs PID 1 before anything has populated /etc, so an init living there could not
  # start. In the store it needs nothing to exist first.
  s6-linux-init = pkgs.s6-linux-init;

  # the skeleton the maker copies in place of its own commented-out examples
  skeleton = pkgs.runCommand "s6-linux-init-skeleton" { } ''
    mkdir -p $out

    # stage 2, once s6-svscan is running on the scandir s6-linux-init prepared. Activation
    # comes first here rather than before PID 1, because unlike dinit and runit this init
    # needs nothing out of /etc to have started - but everything it is about to start does.
    cat > $out/rc.init <<'EOF'
    #!${pkgs.runtimeShell} -e
    rl="$1"
    shift

    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.s6
        s6rc
      ]
    }:$PATH

    ${cfg.activationScript}

    # the generation about to be started, recorded as the running one. Here rather than in
    # activation, which runs on every switch too - rewriting these then would tell the next
    # `list` that whatever is running was already what is being switched into.
    rm -rf ${runFingerprints}
    cp -rL ${fingerprintDir} ${runFingerprints}
    chmod -R u+w ${runFingerprints}

    s6-rc-init -c ${database}/db -l ${live} ${scanDir}
    exec s6-rc -l ${live} -v2 -up change everything
    EOF

    # called by runleveld for `telinit`. The contract has one bundle rather than runlevels -
    # what would have been a runlevel is a trunk level, and reaching one is a matter of its
    # dependencies having started - so every state change is the same state change.
    cat > $out/runlevel <<'EOF'
    #!${pkgs.runtimeShell} -e
    exec ${lib.getExe' s6rc "s6-rc"} -l ${live} -v2 -up change everything
    EOF

    # the way down. s6-rc brings the whole set down in dependency order, which is the shutdown
    # side of the trunk falling out of the graph rather than a sequence written by hand - finit
    # needed a generated script for this and dinit an inverted chain of stop-commands.
    cat > $out/rc.shutdown <<'EOF'
    #!${pkgs.runtimeShell} -e
    exec >/dev/console 2>&1

    # everything the database knows about, brought down in dependency order first - so the
    # contract's shutdown side runs with the boot side already stopped, which is what the latch
    # means. Not exec'd, because there is something to do afterwards.
    ${lib.getExe' s6rc "s6-rc"} -l ${live} -v2 -bDa change

    ${lib.optionalString (shutdownScript != null) shutdownScript}
    EOF

    # deliberately empty: everything is already down and unmounted by this point
    cat > $out/rc.shutdown.final <<'EOF'
    #!${pkgs.runtimeShell} -e
    EOF

    chmod +x $out/rc.init $out/rc.runlevel 2>/dev/null || true
    chmod +x $out/*
  '';

  # where the generated init directory is unpacked at boot, and so the location baked into
  # every script the maker writes. Not under /run: s6-linux-init mounts its own tmpfs there.
  initBase = "/s6-linux-init";

  # a tarball rather than a directory, because run-image contains two fifos - one of them the
  # channel s6-linux-init-shutdownd listens on - and a Nix store cannot hold a fifo at all.
  # Archiving preserves them; the wrapper below unpacks it before the real init runs.
  #
  # fakeroot because the maker chowns run-image/uncaught-logs to the catch-all logger's user,
  # which a build cannot do - it reports that as "unable to mkdir", which is misleading enough
  # to be worth writing down.
  initImage =
    pkgs.runCommand "s6-linux-init-image"
      {
        nativeBuildInputs = [
          s6-linux-init
          pkgs.fakeroot
          pkgs.gnutar
        ];
      }
      ''
        fakeroot bash -c '
          s6-linux-init-maker \
            -c ${initBase} \
            -p ${
              lib.makeBinPath [
                pkgs.coreutils
                pkgs.s6
                s6rc
              ]
            } \
            -f ${skeleton} \
            -1 \
            -u root \
            "$TMPDIR/gen"

          tar -C "$TMPDIR/gen" -cf $out .
        '
      '';

  initWrapper = pkgs.writeShellScript "s6-init" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnutar
      ]
    }:$PATH

    mkdir -p ${initBase}
    tar -xf ${initImage} -C ${initBase}

    exec ${initBase}/bin/init "$@"
  '';
in
{
  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "s6-rc" ];
    };

    s6-rc.database = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = ''
        The compiled service database.

        s6-rc runs against a database rather than a directory of configuration, so this is
        built rather than written out - a malformed unit fails the build instead of the boot.

        Hosting is the system's business, as s6-rc supervises under whatever is PID 1:
        `s6-svscan` over a scan directory, then `s6-rc-init -c <this>/db -l ${live}` against it.
        See `tests/providers/services-s6rc.nix`.
      '';
    };
  };

  config = lib.mkIf (cfg.backend == "s6-rc") {
    providers.services.s6-rc.database = database;

    providers.services.supportedFeatures = {
      # `timeout-up` and `timeout-down`, per unit
      startTimeout = true;
      stopTimeout = true;

      # s6 speaks its own protocol natively and has no notion of sd_notify. The waitFor kinds
      # are turned into an s6 notification by the run script, which waits beside the daemon and
      # writes the descriptor s6 is already listening on.
      #
      # `waitFor.pidfile` is the exception, and s6 has no notion of a pid file at all: the kind
      # means the spawned process forks and exits, which s6-supervise reads as the service
      # dying and restarts, forever. Waiting for the file would work and the supervision would
      # not, so it is refused.
      readiness = [
        "fork"
        "s6"
        "waitFor.socket"
        "waitFor.path"
        "waitFor.check"
      ];

      user = true;
      group = false;
      path = true;
    };

    providers.services.switch = {
      list = pkgs.writeShellScript "s6-rc-list" ''
        # s6-rc decides what is running; the fingerprint only says which definition it was
        # started from, which the supervisor cannot be asked. A missing record therefore does
        # not remove the unit from the list - one brought up by hand has none, and omitting it
        # would leave the engine unable to see, and so unable to stop, something that is
        # running. `unknown` cannot equal a real fingerprint, so such a unit is reconciled.
        ${reportUnmanaged}
        known=" ${lib.concatStringsSep " " (lib.attrNames atomic)} "

        ${lib.getExe' s6rc "s6-rc"} -l ${live} -a list 2>/dev/null | while read -r unit; do
          # s6-rc's own internals are in the live state too - `s6rc-oneshot-runner` most of
          # all - and they are not units. Reporting one puts it in a list the engine reconciles
          # against the incoming tree, where it can never appear, so the engine would stop it
          # and take s6-rc's ability to run a oneshot with it.
          case "$known" in
            *" $unit "*) ;;
            *) continue ;;
          esac

          fp="${runFingerprints}/$unit"
          if [ -e "$fp" ]; then
            printf '%s\t%s\n' "$unit" "$(cat "$fp")"
          else
            printf '%s\tunknown\n' "$unit"
          fi
        done
      '';

      # `change` is bulk and atomic, which is what the engine hands it anyway
      activate = pkgs.writeShellScript "s6-rc-activate" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

        ${knownFilter}
        [ -n "$units" ] || exit 0

        # the live database is the one compiled into the generation that booted, and s6-rc will
        # not start a service it does not contain - so a unit which is new in this generation
        # could never come up, however the engine asked. `s6-rc-update` migrates the live state
        # onto the incoming database, keeping what is running running.
        #
        # In activate rather than deactivate: the engine stops before it starts, and a unit
        # being removed exists only in the outgoing database. Updating first would take it out
        # from under the stop.
        ${lib.getExe' s6rc "s6-rc-update"} -v2 -t 30000 -l ${live} ${database}/db

        ${lib.getExe' s6rc "s6-rc"} -v2 -t 30000 -l ${live} -u change $units

        # what is now running, recorded where the next switch will look. After the change, so
        # a unit which failed to come up is not claimed as this generation's.
        mkdir -p ${runFingerprints}
        for unit in $units; do
          if [ -e ${fingerprintDir}/"$unit" ]; then
            cp -f ${fingerprintDir}/"$unit" ${runFingerprints}/"$unit"
          fi
        done
      '';

      deactivate = pkgs.writeShellScript "s6-rc-deactivate" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

        ${knownFilter}
        [ -n "$units" ] || exit 0

        ${lib.getExe' s6rc "s6-rc"} -v2 -t 30000 -l ${live} -d change $units

        # no longer running, so no longer this generation's
        for unit in $units; do
          rm -f ${runFingerprints}/"$unit"
        done
      '';
    };

    # s6's boot, as PID 1.
    #
    # s6-svscan is what supervises and what reaps, so it has to be the process the kernel is
    # left with - hence the exec. But a compiled database is not something a scan directory
    # notices: it has to be initialised against a scan directory which is already live, which
    # cannot happen before s6-svscan is running. So the initialisation is forked off first and
    # waits for the supervisor it is about to talk to.
    #
    # s6-linux-init exists to do exactly this and would replace the whole script, at the cost
    # of a generated init directory to keep in step with the contract's own output.
    # s6-linux-init prepares /run, populates the scandir from its run-image, starts s6-svscan
    # on it, and only then runs rc.init - so the database is brought up against a scandir which
    # is already live, with no polling for a control fifo to appear.
    providers.services.initExecutable = initWrapper;

    # s6-linux-init-maker generates these three beside the init it generates, each one talking
    # to s6-linux-init-shutdownd over the fifo in the run-image. So they are named under the
    # unpacked directory rather than in the store: the store copy is inside a tarball, because
    # that fifo cannot be a store path, and ${initBase} is where initWrapper unpacks it.
    providers.services.shutdownCommands = {
      poweroff = "${initBase}/bin/poweroff";
      reboot = "${initBase}/bin/reboot";
      halt = "${initBase}/bin/halt";
    };

    # no fingerprints in /etc: see runFingerprints above. Activation replaces /etc before the
    # engine is ever asked what is running, so /etc can only ever describe the generation being
    # switched into.
  };
}
