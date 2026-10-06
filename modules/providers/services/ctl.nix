# one front-end for inspecting and controlling units, whichever init is underneath
#
# The primitives for this already existed and were only reachable one backend at a time. Every
# implementation supplies `switch.list`, `switch.activate` and `switch.deactivate` - that is what
# reconciles a generation - and `shutdownCommands`, which is how the machine halts. What was
# missing was a way to ask for one unit by name, and a way to reach a *user's* supervisor at all:
# its socket path was a convention inside the dinit module and nothing surfaced it.
#
# So the shape of the problem was a tool per backend per tree. On this machine that meant finit's
# `initctl` on PATH talking to an init which is not running, `dinitctl` not installed despite
# dinit supervising the whole session, and the user tree reachable only by naming both the store
# path of a binary and the socket it wants.
#
# `initctl` is installed at `hiPrio`, the same way the shutdown commands already are and for the
# same reason: every implementation ships a tool under some well-known name, each one talks only
# to its own init, and the wrong one is a command that reports a failure rather than doing
# nothing. One name, resolved to the backend this machine actually runs.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  sw = cfg.switch;

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;
  userTrees = lib.filterAttrs (_: t: t.units != { }) cfg.users;

  # whether there is anything to control: the system tree needs the three operations, and a
  # user tree needs a way in. Reported rather than assumed, the same way `switch.supported` is.
  supported =
    sw.supported
    && cfg.ctl.status != null
    && (userTrees != { } -> (cfg.user.ctl != null && cfg.user.status != null));

  # which tree owns each name, decided here rather than by asking.
  #
  # The names are known at build time, so a lookup table answers "who owns `mako`" without
  # opening a conversation with every supervisor on the machine to find out. It also means a
  # name that exists in two trees can be reported as ambiguous instead of acted on in whichever
  # one answered first.
  index =
    map (n: {
      tree = "system";
      unit = n;
    }) (lib.attrNames enabled)
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: tree:
        map (n: {
          tree = user;
          unit = n;
        }) (lib.attrNames tree.units)
      ) userTrees
    );

  # everything the tool reaches for, as data.
  #
  # Each of these is a command line some backend filled in, and that is the whole design: one
  # front-end, seven implementations, none of which this has to understand. A backend is added by
  # filling in the options below and nothing in pkgs/finix-ctl changes.
  manifest = pkgs.writeText "initctl-manifest.json" (
    builtins.toJSON {
      shell = lib.getExe pkgs.bash;

      inherit index;

      system = {
        status = cfg.ctl.status;
        activate = toString sw.activate;
        deactivate = toString sw.deactivate;
      };

      users = lib.optionalAttrs (cfg.user.ctl != null && cfg.user.status != null) (
        lib.mapAttrs (user: _: {
          ctl = cfg.user.ctl user;
          status = cfg.user.status user;
        }) userTrees
      );

      shutdown = {
        reboot = cfg.shutdownCommands.reboot or null;
        poweroff = cfg.shutdownCommands.poweroff or null;
        halt = cfg.shutdownCommands.halt or null;
      };
    }
  );

  # `makeBinaryWrapper`, not `makeWrapper`: the latter writes a shell script, and the point of
  # the port was to stop this command being one. The compiled wrapper execs straight through with
  # the manifest prepended, so `initctl` on PATH is an ELF from the first instruction.
  #
  # A wrapper at all because the manifest is per-configuration and the binary is not: it is built
  # once and this is what binds it to the generation it was evaluated for.
  initctl = pkgs.runCommand "initctl" { nativeBuildInputs = [ pkgs.makeBinaryWrapper ]; } ''
    mkdir -p $out/bin
    makeWrapper ${lib.getExe (pkgs.callPackage ../../../pkgs/finix-ctl { })} $out/bin/initctl \
      --add-flags ${manifest}
  '';
in
{
  options.providers.services = {
    ctl.status = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      internal = true;
      description = ''
        A command reporting every unit in the system tree as `name<TAB>state`, one per line.

        The state is one of `running`, `done`, `stopped` or `unknown`, and an implementation maps
        its own notion onto those rather than reporting its own words. The vocabulary is part of
        the contract because this is read by a person looking at one list: the first version let
        each backend answer in its own terms and the same listing then said `running` for a unit
        the system tree supervises and `STARTED` for one the session does, which is two names for
        one thing in adjacent rows.

        `done` is a unit which ran to completion and is meant to have no process - a oneshot. An
        implementation with no notion of that reports `stopped`, which is true of it.

        Distinct from {option}`providers.services.switch.list`, which reports name and
        fingerprint for reconciliation and says nothing a person wants to read. An
        implementation which cannot report state leaves this null, and `initctl` is then not
        installed rather than installed and broken.
      '';
    };

    user.status = lib.mkOption {
      type = with lib.types; nullOr (functionTo str);
      default = null;
      internal = true;
      description = ''
        Given a user, a command reporting that user's units as `name<TAB>state` - the same shape
        as {option}`providers.services.ctl.status` reports the system's.

        Separate from {option}`providers.services.user.ctl` because listing and controlling are
        not the same question: `ctl` names a unit to act on, and this reports all of them. Both
        so that one listing can show every tree on the machine without a reader having to know
        which supervisor each row came from.
      '';
    };

    user.ctl = lib.mkOption {
      type = with lib.types; nullOr (functionTo str);
      default = null;
      internal = true;
      description = ''
        Given a user, the command which controls that user's tree - taking a subcommand and a
        unit name, as `dinitctl` does.

        A user's supervisor is reached over its own socket, and where that socket is belongs to
        the implementation running it: before this the path was a convention inside the dinit
        module, so the only way to reach the session's own units was to name both the store path
        of a binary and the socket by hand.
      '';
    };
  };

  config = {
    environment.systemPackages = lib.mkIf supported [ (lib.hiPrio initctl) ];

    warnings = lib.optional (cfg.backend != "none" && cfg.units != { } && !supported) ''
      the ${cfg.backend} services provider does not report unit state, so `initctl` is not
      installed - inspecting units needs that implementation's own tool.
    '';
  };
}
