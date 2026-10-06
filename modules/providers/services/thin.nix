# the shared half of a thin backend: everything sinit and nxinit do identically
#
# The two inits present the same surface - block signals, exec one child, answer a signal each
# for reboot and poweroff - so the supervision built on top of them was the same, and used to be
# the same *twice*: two modules, four hundred lines apiece, maintained by hand in parallel. The
# shutdown bug that prompted this was in both of them, written once and copied.
#
# What is genuinely per-backend is small and stays in each module: the package, which signals
# mean what, whether Ctrl-Alt-Del reaches pid 1, and nxinit's /dev/fd `pre` op. Everything else -
# the manifest, the entry points, switch, status, the feature set - is here.
#
# This generates data, not shell. The job scripts, rc.init and rc.shutdown became
# `pkgs/finix-rc`; what Nix still does is exactly what it did before - resolve the graph at
# evaluation time, so that nothing at boot has to - but the result is written as JSON a program
# reads rather than as text a shell interprets. See pkgs/finix-rc/src/main.rs.
{
  pkgs,
  lib,
}:
let
  readinessLib = import ./readiness.nix { inherit pkgs lib; };
  shutdownLib = import ./shutdown.nix { inherit pkgs lib; };

  finixRc = lib.getExe (pkgs.callPackage ../../../pkgs/finix-rc { });

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};
in
rec {
  # the one path on the running system this backend knows. See pkgs/finix-rc/src/latch.rs: the
  # layout inside it is an ABI, read by `switch`, by `ctl status` and by anyone measuring a boot
  # out of the `.ready` files, which is why the port left it alone.
  latchDir = "/run/providers-services";

  # everything Nix resolves, as one file.
  #
  # `requires` is already flattened - every trunk edge and every explicit `requires` - so nothing
  # at boot searches or orders anything. That is the property the measurement which chose these
  # backends depends on, and moving from generated shell to generated JSON does not touch it.
  manifestFor =
    cfg:
    let
      enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

      unitJson =
        name: unit:
        let
          kind = kindOf unit;
          v = variantOf unit;
        in
        {
          fingerprint = cfg.switch.fingerprints.${name};
          requires = unit.requires;
          inherit kind;
          command = v.command or null;
          user = unit.user;
          group = unit.group;

          # `lib.makeBinPath` joins with colons and the binary wants the elements, so this is the
          # same function read back apart. Written this way rather than mapping over `unit.path`
          # directly because `makeBinPath` is what every other backend uses and `getBin` is not
          # always `"${p}/bin"`.
          path = lib.filter (s: s != "") (lib.splitString ":" (lib.makeBinPath unit.path));

          environment = unit.environment;

          # null means `fork` readiness - up the moment it is running. `notify` and `s6` never
          # reach here; the contract refuses them against these backends.
          readiness_command =
            if kind == "service" then readinessLib.scriptFor name v.readiness else null;

          shutdown_side = shutdownLib.onShutdownSide cfg.trunk name unit;
        };
    in
    pkgs.writeText "finix-rc-manifest.json" (
      builtins.toJSON {
        latch_dir = latchDir;

        # the contract types a unit's `command` as "main program, path or command", so it is a
        # command line and something has to parse it. This is the same bash that interpolated it
        # inline when these were shell scripts, which is what keeps the port behaviour-preserving
        # for a unit whose command relies on being shell.
        shell = lib.getExe pkgs.bash;

        # runit's, for privilege dropping. See pkgs/finix-rc/src/job.rs for why this is still a
        # command: `chpst -u user` resolves the primary group out of the passwd entry and the
        # supplementary groups out of the group database, and reimplementing NSS lookup to save
        # one exec at unit start is a bad trade in the one place the contract promises something
        # about privilege.
        chpst = lib.getExe' pkgs.runit "chpst";

        shutdown_command = shutdownLib.scriptFor cfg;

        units = lib.mapAttrs unitJson enabled;
      }
    );

  # Both inits take `rcinit` and `rcshutdown` as single compiled-in paths - suckless style, no
  # argv and no configuration file - so neither can be handed `finix-rc init <manifest>` directly
  # and each needs one executable of its own.
  #
  # These two lines are the only shell left on this backend, and they are the only shell that
  # cannot be removed without changing an init: the alternative is a per-generation copy of the
  # binary so that /proc/self/exe lands beside its manifest, which trades two lines of `exec` for
  # a duplicated binary per generation.
  #
  # `rc.shutdown` is spawned by pid 1 as `rc.shutdown reboot` or `rc.shutdown poweroff`, so the
  # action arrives as `$1` and is passed straight through. It is immediately parsed into a value
  # and never read as a positional parameter again - which is the entire bug this replaces; see
  # pkgs/finix-rc/src/shutdown.rs.
  entryPointsFor = cfg: rec {
    manifest = manifestFor cfg;

    rcinit = pkgs.writeShellScript "rc.init" ''
      exec ${finixRc} init ${manifest}
    '';

    rcshutdown = pkgs.writeShellScript "rc.shutdown" ''
      exec ${finixRc} shutdown ${manifest} "$1"
    '';
  };

  switchFor =
    cfg:
    let
      manifest = manifestFor cfg;
    in
    {
      list = pkgs.writeShellScript "finix-rc-list" ''
        exec ${finixRc} list ${manifest}
      '';

      activate = pkgs.writeShellScript "finix-rc-activate" ''
        exec ${finixRc} activate ${manifest}
      '';

      deactivate = pkgs.writeShellScript "finix-rc-deactivate" ''
        exec ${finixRc} deactivate ${manifest}
      '';
    };

  statusFor = cfg: "${finixRc} status ${manifestFor cfg}";

  # identical on both, and for the same reasons - neither init supervises, observes or bounds
  # anything, so every one of these is a statement about what finix-rc does.
  supportedFeatures = {
    # neither is bounded: stopping is TERM then KILL on a fixed schedule, and nothing times a
    # unit's own start out.
    startTimeout = false;
    stopTimeout = false;

    # `waitFor.pidfile` is refused for the reason it is on runit: it says the daemon forks and
    # the spawned process exits, which the respawn loop would read as a crash and restart for
    # ever. `notify` and `s6` are protocols nothing here speaks.
    readiness = [
      "fork"
      "waitFor.socket"
      "waitFor.path"
      "waitFor.check"
    ];

    user = true;
    group = true;
    path = true;
  };
}
