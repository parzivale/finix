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

  readinessLib = import ../../providers/services/readiness.nix {
    inherit pkgs lib;
  };
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
      }${commandOf unit}${
        # the descriptor is appended here rather than written into the unit: s6 always uses 3,
        # finit substitutes its own, and which it is belongs to the supervisor. The unit says
        # only which option its daemon takes to be told.
        # guarded on the kind: this script is a oneshot's `up` as well as a longrun's `run`,
        # and only a service has readiness at all
        lib.optionalString (
          kindOf unit == "service" && readinessOf unit == "s6" && (variantOf unit).readiness.s6.flag != null
        ) " ${(variantOf unit).readiness.s6.flag} 3"
      }
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
  # the whole point of this backend: the database is built here, not assembled at boot. a
  # configuration error is a build failure rather than something discovered on the machine.
  #
  # A function of the scope, because a user's tree is the same compilation over a different unit
  # set. Nothing else about `unitDir` or `runScript` is scope-bound - s6 needs no latch files
  # and no writable copy of anything, the database being read-only and `s6-rc-init` populating
  # the scan directory from it - so this is the whole of what the user scope needed from the
  # system's machinery.
  databaseFor =
    label: units:
    pkgs.runCommand "s6-rc-database-${label}" { nativeBuildInputs = [ s6rc ]; } ''
      mkdir -p $out
      ${lib.concatStrings (lib.mapAttrsToList unitDir units)}

      mkdir -p $out/source/everything
      printf 'bundle\n' > $out/source/everything/type
      printf '%s' ${
        lib.escapeShellArg (lib.concatMapStrings (n: "${n}\n") (lib.attrNames units))
      } > $out/source/everything/contents

      s6-rc-compile $out/db $out/source
    '';

  database = databaseFor "system" bootSide;

  live = "/run/s6-rc";
  scanDir = "/run/service";

  # ---- the user scope ----------------------------------------------------------------
  #
  # s6 supervises a user's tree with the same two programs it supervises the system's with, and
  # neither wants to be pid 1 or to be root: `s6-svscan` watches a directory and `s6-rc` changes
  # state against a live directory. What differs is where those live and who may write to them.
  #
  # Less had to be rearranged here than for any other backend. The database is compiled into the
  # store and read from there, so unlike runit there is nothing to copy out; `s6-rc-init`
  # populates the scan directory itself from that database, so unlike dinit there is no tree to
  # write into /etc; and s6 speaks readiness natively, so unlike runit there are no latch files
  # to keep per scope.
  userRoot = user: "/run/user-services/${user}";
  userLive = user: "${userRoot user}/live";
  userScanDir = user: "${userRoot user}/service";

  userUnits = u: lib.filterAttrs (_: unit: unit.enable) u.units;
  userDatabase = user: u: databaseFor "user-${user}" (userUnits u);

  # the teardown, and it is s6's own mechanism rather than anything of the contract's.
  #
  # `supervisor.stopSignal` stays TERM, which is what s6-svscan already means: s6-svscan(1) -
  # "Instruct all the s6-supervise processes to stop their service and exit; wait for the whole
  # supervision tree to die [...] then exec into .s6-svscan/finish or exit 0". The exact
  # opposite of runit, where TERM makes runsvdir exit and abandon everything it was watching.
  #
  # What this script adds is the order. A bare TERM stops every service at once; bringing the
  # set down through `s6-rc` first stops them in dependency order, which is what the system's
  # own rc.shutdown does with the same command. The live directory goes with it, so the next
  # session starts from nothing rather than finding a database already initialised.
  userSigterm =
    user:
    pkgs.writeShellScript "s6-rc-user-sigterm-${user}" ''
      ${lib.getExe' s6rc "s6-rc"} -l ${userLive user} -bDa change || :
      ${lib.getExe' pkgs.coreutils "rm"} -rf ${userLive user}
      exec ${lib.getExe' pkgs.s6 "s6-svscanctl"} -t ${userScanDir user}
    '';

  # what a session runs. The process the launcher owns is s6-svscan itself - this `exec`s into
  # what a session runs. The process the launcher owns is s6-svscan itself - this `exec`s into
  # it - so stopping it is the signal above and nothing has to stay alive to translate one.
  #
  # The database is copied out of the store first, and that is not an optimisation. s6-rc-init
  # copies the service directories it finds in the database verbatim, modes included, and then
  # writes a `down` file into each copy so that the supervisors it starts do not start the
  # services yet. A database in the store is mode 555, so the copies are 555, and writing into
  # one fails for anybody but root:
  #
  #   s6-rc-init: fatal: unable to supervise service directories in <live>/servicedirs:
  #                      Permission denied
  #
  # which is what s6-rc-init(1) means by "it must be run as root". Root never notices, so the
  # system scope has been handing it a store path since this backend was written. A writable
  # copy per session costs one `cp` of a few kilobytes and is the whole of the difference.
  #
  # The database still has to be initialised against a *running* s6-svscan: `s6-rc-init`
  # populates the scan directory and waits for the supervisors it created to come up, which
  # cannot happen before there is a scanner. So it runs beside, after waiting for the control
  # fifo s6-svscan creates when it is ready - which is also how `s6-svscanctl` knows where to
  # talk, so waiting for it is waiting for exactly the thing that matters.
  userSupervisor =
    user: u:
    toString (
      pkgs.writeShellScript "s6-rc-user-supervisor-${user}" ''
        set -e
        export PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.s6
            s6rc
          ]
        }:$PATH

        # a tree already being supervised here means a second session for this user, and the
        # directories below are not safe to clear underneath it. Refusing is both halves of
        # that: the first session keeps its tree, and the launcher reports a supervisor which
        # exited rather than leaving a session silently without one.
        if [ -p ${userScanDir user}/.s6-svscan/control ]; then
          echo "s6-rc: a supervision tree for ${user} is already running" >&2
          exit 1
        fi

        # from nothing, every session. `s6-rc-init` refuses a live directory which already
        # exists, and a scan directory left behind by a session that crashed would have
        # s6-svscan supervising its service directories before `s6-rc` had any say in what
        # should be up - which is every unit at once, in no order.
        #
        # `chmod` first, because what is being removed may not be writable: a tree left by a
        # generation whose database came from the store has 555 service directories in it, and
        # `rm -rf` cannot empty a directory it cannot write to.
        chmod -R u+w ${userRoot user}/db ${userLive user} ${userScanDir user} 2>/dev/null || :
        rm -rf ${userRoot user}/db ${userLive user} ${userScanDir user}

        cp -rL ${userDatabase user u}/db ${userRoot user}/db
        chmod -R u+rwX ${userRoot user}/db

        mkdir -p ${userScanDir user}/.s6-svscan
        ln -sf ${userSigterm user} ${userScanDir user}/.s6-svscan/SIGTERM

        (
          while [ ! -p ${userScanDir user}/.s6-svscan/control ]; do
            sleep 0.05
          done

          s6-rc-init -c ${userRoot user}/db -l ${userLive user} ${userScanDir user}
          s6-rc -l ${userLive user} -up change everything
        ) &

        exec s6-svscan ${userScanDir user}
      ''
    );

  # `<verb> <unit>`, which is the shape the contract asks for and not s6-rc's own: s6-rc says
  # what state a set should be in - `-u change` up, `-d change` down - rather than taking a verb.
  userCtl =
    user:
    toString (
      pkgs.writeShellScript "s6-rc-user-ctl-${user}" ''
        verb="$1"
        shift

        s6rc() { exec ${lib.getExe' s6rc "s6-rc"} -l ${userLive user} "$@"; }

        case "$verb" in
          start) s6rc -u change "$@" ;;
          stop) s6rc -d change "$@" ;;
          restart)
            ${lib.getExe' s6rc "s6-rc"} -l ${userLive user} -d change "$@"
            s6rc -u change "$@"
            ;;
          status) exec ${lib.getExe' pkgs.s6 "s6-svstat"} ${userScanDir user}/"$1" ;;
          *)
            echo "s6-rc: unknown verb $verb" >&2
            exit 2
            ;;
        esac
      ''
    );

  # the same question the system's `ctl.status` answers, over a user's live directory:
  # membership of the up set is the state, so this asks once rather than per unit.
  userStatus =
    user: u:
    toString (
      pkgs.writeShellScript "s6-rc-user-status-${user}" ''
        up=$(${lib.getExe' s6rc "s6-rc"} -l ${userLive user} -a list 2>/dev/null || :)

        for unit in ${
          lib.concatStringsSep " " (
            lib.attrNames (lib.filterAttrs (_: unit: kindOf unit != "anchor") (userUnits u))
          )
        }; do
          if printf '%s\n' "$up" | ${lib.getExe' pkgs.gnugrep "grep"} -qx -- "$unit"; then
            state=running
          else
            state=stopped
          fi

          printf '%s\t%s\n' "$unit" "$state"
        done
      ''
    );
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

      # activation and the fingerprint copy are finix-init's, not this script's: it runs before
      # s6's init, so /etc is there by the time anything reads it. That only works because the
      # maker is given `-n` above - otherwise s6 would replace the /run finix-init had just put
      # the generation's symlinks in.

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

  # the two channels which cannot be in the store, and so cannot be in `initTree`.
  #
  # A derivation output holds regular files, directories and symlinks. A fifo is none of those, and
  # these two are: the catch-all logger's, and the one s6-linux-init-shutdownd listens on. That is
  # the whole reason this used to be a tarball - archiving preserves the node type, and a wrapper
  # unpacked it before the real init ran.
  #
  # Named rather than discovered, because `pre` is data and discovery happens at build time. The
  # build asserts these are the only two, so a layout change in s6-linux-init breaks it with
  # something to read rather than leaving a boot to fail on a missing channel.
  initFifos = [
    "run-image/service/s6-svscan-log/fifo"
    "run-image/service/s6-linux-init-shutdownd/fifo"
  ];

  # the generated tree, as a directory.
  #
  # fakeroot because the maker calls chown. `-u root` means the catch-all logger is root, so there
  # is no ownership to preserve - but the call itself fails with EPERM in a build sandbox whatever
  # the target uid, and it reports that as "unable to mkdir", which is misleading enough to be
  # worth writing down. Faking the call is enough; nothing needs to survive into the output.
  initTree =
    pkgs.runCommand "s6-linux-init-tree"
      {
        nativeBuildInputs = [
          s6-linux-init
          pkgs.fakeroot
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
            -n \
            -u root \
            "$TMPDIR/gen"

          ${lib.concatMapStringsSep "\n          " (f: ''rm -f "$TMPDIR/gen/${f}"'') initFifos}

          left=$(find "$TMPDIR/gen" -type p -printf "%P\n")
          if [ -n "$left" ]; then
            echo "s6-linux-init-maker made fifos this module does not name:" >&2
            echo "$left" >&2
            echo "add them to initFifos in modules/init/s6-rc/default.nix" >&2
            exit 1
          fi

          cp -a "$TMPDIR/gen" $out
        '
      '';
in
{
  # enabling an implementation is what selects it: this names itself into the contract
  # below, the same way every other providers implementation does when it is enabled.
  options.s6-rc.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether to boot s6 as PID 1, through `s6-linux-init`, supervising with `s6-rc`.

      Enabling it points {option}`providers.services.backend` at `s6-rc`, which is what
      actually selects an implementation - so this is a default, and a machine naming a
      backend directly still wins.
    '';
  };

  # the same question for the user scope, and independent of the one above in both directions:
  # `s6-svscan` is a program that watches a directory, so it serves a session beside any pid 1,
  # and an s6 which *is* pid 1 does not serve a session unless this says so.
  #
  # Named for the role rather than as `s6-rc.user.enable`, matching the dinit, systemd and runit
  # modules.
  options.s6-rc.userSupervisor.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether an `s6-svscan` started by each user's session supervises that user's units,
      with `s6-rc` bringing them up against it.

      Enabling it points {option}`providers.services.user.backend` at `s6-rc`, which is what
      actually selects an implementation for that scope - so this is a default, and a machine
      naming a backend directly still wins.

      Independent of {option}`s6-rc.enable`. With no {option}`providers.services.users`
      declared it names an implementation for a scope with nothing in it, which is inert.
    '';
  };

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

  config = lib.mkMerge [
    # this module supplies an implementation for `providers.services`
    (lib.mkIf config.s6-rc.enable {
      providers.services.backend = lib.mkDefault "s6-rc";
    })

    # and the user scope, which is a separate claim - see the block above `userSupervisor` for
    # why an s6-svscan per session beside a different pid 1 is the intended shape.
    (lib.mkIf config.s6-rc.userSupervisor.enable {
      providers.services.user.backend = lib.mkDefault "s6-rc";
    })

    (lib.mkIf (cfg.user.backend == "s6-rc") {
      providers.services.user.manager.supervisor.command = user: [
        (userSupervisor user cfg.users.${user})
      ];

      # no `stop`, and `stopSignal` left at its default: TERM is already what s6-svscan means
      # by stop. See `userSigterm`, which the scan directory names so that the set comes down in
      # dependency order rather than all at once.

      providers.services.user.ctl = userCtl;
      providers.services.user.status = user: userStatus user cfg.users.${user};

      # the user's root, which has to exist and belong to them before their session can write a
      # live directory and a scan directory into it - and so is boot work, being the one part of
      # this that needs root. The same unit the dinit and runit backends declare for the same
      # reason; only one implementation serves this scope on a machine, so only one is emitted.
      providers.services.units = lib.mapAttrs' (
        user: _:
        lib.nameValuePair "user-services-dir--${user}" {
          description = "supervision directory for ${user}";
          requires = [ "sysinit" ];
          type.oneshot.command = pkgs.writeShellScript "user-services-dir-${user}" ''
            ${lib.getExe' pkgs.coreutils "mkdir"} -p ${userRoot user}
            ${lib.getExe' pkgs.coreutils "chown"} ${user} ${userRoot user}
          '';
        }
      ) cfg.users;
    })

    (lib.mkIf (cfg.backend == "s6-rc") {
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

      # s6-rc's live state lists what is up, which is what `switch.list` below reads. Membership
      # is the state, so this asks once and compares names rather than calling s6-svstat per
      # unit.
      #
      # Over the atomic units - the ones with something to supervise - because a bundle is a
      # compile-time name for a set and has no state of its own to report.
      providers.services.ctl.status = toString (
        pkgs.writeShellScript "s6-rc-status" ''
          up=$(${lib.getExe' s6rc "s6-rc"} -l ${live} -a list 2>/dev/null || :)

          for unit in ${lib.concatStringsSep " " (lib.attrNames atomic)}; do
            if printf '%s\n' "$up" | ${lib.getExe' pkgs.gnugrep "grep"} -qx -- "$unit"; then
              state=running
            else
              state=stopped
            fi

            printf '%s\t%s\n' "$unit" "$state"
          done
        ''
      );

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
      # s6's own init, directly. There is no wrapper any more.
      #
      # What the wrapper did was untar the generated tree, because two of its entries are fifos and
      # a store path cannot hold one. `pre` does that as data now: the tree is an ordinary store
      # directory, copied where the maker baked its own location, and the two channels made
      # afterwards. gnutar and coreutils leave the boot path with it.
      providers.services.exec = [ "${initBase}/bin/init" ];

      providers.services.pre = [
        # the generated tree, where every script in it expects to be. Writable because s6 writes
        # into run-image as it runs, and dereferenced because a copy of store symlinks would be a
        # tree of read-only paths.
        {
          op = "copyTree";
          from = initTree;
          to = initBase;
          writable = true;
        }
      ]
      ++ map (f: {
        op = "mkfifo";
        path = "${initBase}/${f}";
        mode = 384; # 0600, as the maker makes them
      }) initFifos
      ++ [
        # the generation about to be started, recorded as the running one. Before the exec rather
        # than in activation, which runs on every switch too: rewriting these then would tell the
        # next `list` that whatever is running was already what is being switched into.
        {
          op = "copyTree";
          from = fingerprintDir;
          to = runFingerprints;
          writable = true;
        }
      ];

      # s6-linux-init-maker generates these three beside the init it generates, each one talking
      # to s6-linux-init-shutdownd over the fifo in the run-image. So they are named under the
      # unpacked directory rather than in the store: the store copy is inside a tarball, because
      # that fifo cannot be a store path, and ${initBase} is where `pre` copies the tree.
      providers.services.shutdownCommands = {
        poweroff = "${initBase}/bin/poweroff";
        reboot = "${initBase}/bin/reboot";
        halt = "${initBase}/bin/halt";
      };

      # no fingerprints in /etc: see runFingerprints above. Activation replaces /etc before the
      # engine is ever asked what is running, so /etc can only ever describe the generation being
      # switched into.
    })
  ];
}
