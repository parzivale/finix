# per-user service trees, and how a login session starts one.
#
# a user's units are not the system's units run under a different uid. they belong to a
# supervisor of that user's own, started by their session and stopped when it ends, and that
# lifetime is the whole point: it is what lets a unit inherit the session's environment rather
# than be told about it afterwards.
#
# which is why there is only one rule here. a supervisor which is already running when the
# session begins - the system's own, or a per-user one started at boot - cannot inherit
# anything, and has to be handed the session's environment through some channel of its own
# afterwards: `dinitctl setenv`, an `env:file` finit sources per stanza, systemd's
# `import-environment`. every one of those is a mechanism for working around a supervisor that
# outlives the thing it is supervising for. starting it from inside the session removes the
# problem instead of plumbing around it.
#
# the cost is that this needs an implementation which can run as a user, and not every one can.
# finit cannot today - `getpid() != 1` and a non-root euid is `EX_NOPERM`, with the per-user
# design sketched in a comment beside it - so naming a tree without naming a supervisor is an
# eval error rather than a quietly different shape.
{
  config,
  options,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  # the head of the trunk, which a user tree has one of too.
  #
  # `units.<name>.requires` defaults to it - "attach to the head of the tree you are in" - and
  # that default is the shared unit type's, so a user unit which says nothing about ordering gets
  # it as well. Rather than special-case the default, the tree is given the head it names: the
  # implementation emits an anchor of this name beside the user's own units, in the user's own
  # namespace, so the edge resolves where every other in-tree edge does.
  #
  # Without it, every user unit that did not write `requires` explicitly failed the check below
  # against a level it never asked for.
  head = lib.head cfg.trunk.levels;

  # edges leaving a user's own tree. a separate supervisor cannot observe the system's units, so
  # these name something it will never see: the unit waits for a dependency that cannot arrive.
  #
  # what to do about one is always the same - move the thing being waited for earlier in the
  # trunk, so it is already up by the time any session can start - and never to add the edge,
  # because there is nowhere for it to go.
  crossTree = lib.concatLists (
    lib.mapAttrsToList (
      user: u:
      lib.concatLists (
        lib.mapAttrsToList (
          name: unit:
          map (dep: "providers.services.users.${user}.units.${name} -> ${dep}") (
            lib.filter (dep: dep != head && !(u.units ? ${dep})) unit.requires
          )
        ) u.units
      )
    ) cfg.users
  );

  # the launcher, which is a binary - see pkgs/finix-session-launch. What it does and in which
  # order is documented there; what is here is the configuration it reads, and the one design
  # decision worth stating at this end: it is a directory of files rather than a format.
  #
  # Files because the alternative was a parser. Everything the launcher needs is a string - a
  # command, a signal name, a variable's value - and a tree of one-value files is read with
  # `fs::read_to_string` and nothing else, which keeps the crate dependency-free the way
  # finix-wait is. The shape is:
  #
  #   stop-signal              the signal which stops a supervisor; see `supervisor.stopSignal`
  #   kill                     coreutils' kill, which is how a named signal is sent
  #   shell                    what runs the commands below
  #   users/<name>/supervisor  `supervisor.command` for that user
  #   users/<name>/stop        `supervisor.stop`, where the implementation has one
  #   users/<name>/variables   her `sessionVariables`, one NAME=VALUE per line
  #
  # Baked into /etc rather than passed as arguments so that a session names a user and nothing
  # else: what supervises their tree is the implementation's business, and a session which had
  # to spell it out would be naming a backend - the one thing a `providers` consumer never does.
  launcherPackage = pkgs.callPackage ../../../pkgs/finix-session-launch { };

  hasSupervisor = cfg.user.manager ? supervisor;

  # one NAME=VALUE per line, and the values are literal now. The shell this replaced exported
  # them from inside double quotes, so a value could extend the variable it was replacing the way
  # `environment.d(5)` allows - and, being shell, a value containing a command substitution would
  # have run it. Nothing here expands anything, which is the point: a variable's value is a
  # string, and `$HOME/x` now means a path with a dollar in it.
  #
  # `providers.services.users.<name>.sessionVariables` warns about a value which looks like it
  # expected otherwise; see the assertion below.
  variablesFile =
    vars:
    pkgs.writeText "session-variables" (
      lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "${name}=${value}") vars)
    );

  # an argv, one argument per line. Which is the format and not an encoding: an argument with a
  # space in it is one line and so still one argument, and nothing needs quoting because nothing
  # parses it. What a line-per-argument file cannot carry is an argument containing a newline,
  # which no store path and no value in this contract has.
  argvFile = name: argv: pkgs.writeText name (lib.concatStringsSep "\n" argv);

  launcherConfig = pkgs.runCommandLocal "session-launch-config" { } (
    ''
      mkdir -p $out/users
      printf '%s' ${
        lib.escapeShellArg (if hasSupervisor then cfg.user.manager.supervisor.stopSignal else "TERM")
      } > $out/stop-signal
      printf '%s' ${lib.getExe' pkgs.coreutils "kill"} > $out/kill
    ''
    + lib.concatMapStrings (
      user:
      let
        u = cfg.users.${user};
      in
      ''
        mkdir -p $out/users/${user}
      ''
      + lib.optionalString hasSupervisor ''
        cp ${argvFile "supervisor-${user}" (cfg.user.manager.supervisor.command user)} $out/users/${user}/supervisor
      ''
      + lib.optionalString (hasSupervisor && cfg.user.manager.supervisor.stop != null) ''
        cp ${argvFile "supervisor-stop-${user}" (cfg.user.manager.supervisor.stop user)} $out/users/${user}/stop
      ''
      + lib.optionalString (u.sessionVariables != { }) ''
        cp ${variablesFile u.sessionVariables} $out/users/${user}/variables
      ''
    ) (lib.attrNames cfg.users)
  );

  # the executable itself, and a symlink rather than the package: this option is interpolated
  # straight into greetd's configuration and into tests as one path with no arguments, which a
  # derivation with a `bin/` in it would break.
  launcher = pkgs.runCommandLocal "session-launch" { } ''
    ln -s ${lib.getExe launcherPackage} $out
  '';
in
{
  options.providers.services = {
    user.backend = lib.mkOption {
      # the same enum `backend` is, so it carries the set of implementations this configuration
      # actually imports and naming one it does not is a type error listing the alternatives.
      # only `./init/finit` is imported by default; the rest are opted into, and without that
      # import "dinit cannot run as a user" would be the report for a dinit that was never there.
      type = lib.types.nullOr options.providers.services.backend.type;
      default = null;
      description = ''
        The implementation supervising per-user units, or null for a machine with none.

        It need not be the implementation running the system, and usually is not: the system's
        is PID 1 and cannot also be one user's, so this names whichever one can serve that
        scope. Every user tree is then supervised by an instance of it started by that user's
        session.

        There is no default. An implementation which cannot run as a user leaves
        {option}`providers.services.user.manager` at `none`, and naming
        {option}`providers.services.users` without an implementation that can is refused - see
        the assertion there.
      '';
    };

    user.manager = lib.mkOption {
      internal = true;
      default = {
        none = { };
      };
      description = ''
        What the implementation named by {option}`providers.services.user.backend` can do for
        the user scope. Set by that implementation, not by a machine.
      '';
      type = lib.types.attrTag {
        none = lib.mkOption {
          description = ''
            This implementation cannot supervise a user's tree. It is the default, so an
            implementation says this by saying nothing - which is the safe way round: a new
            backend that has not thought about the user scope offers no user services, rather
            than offering a broken one.
          '';
          type = lib.types.submodule { };
        };

        supervisor = lib.mkOption {
          description = ''
            This implementation has a per-user mode and can be one user's own supervisor.
          '';
          type = lib.types.submodule {
            options.command = lib.mkOption {
              type = lib.types.functionTo (lib.types.listOf lib.types.str);
              description = ''
                Given a username, the argv which supervises that user's units - the program and
                its arguments, executed directly. There is no shell, so a value here is never
                interpreted: a redirection or a pipe among these would be a literal argument.

                It is run by {option}`providers.services.user.sessionLauncher`, as the user,
                inside their session - so it inherits that session's environment, and must not
                daemonise away from it.
              '';
            };

            # stopping one, which is two questions rather than one. Most supervisors stop when
            # the process the launcher owns is signalled, and differ only in which signal;
            # for one of them that process is not the supervisor at all.
            options.stopSignal = lib.mkOption {
              type = lib.types.str;
              default = "TERM";
              example = "HUP";
              description = ''
                The signal which asks this implementation's supervisor to stop supervising,
                sent by {option}`providers.services.user.sessionLauncher` to the process it
                started when the session ends.

                TERM for almost everything, and `HUP` for runit, where the difference is not
                cosmetic: `runsvdir` on TERM "exits with 0 immediately" and leaves every
                `runsv` it was monitoring running, so the session would end, the supervisor
                would exit cleanly, and the whole tree would stay - which from the outside is
                indistinguishable from a correct teardown.

                The launcher escalates to SIGKILL if the process is still there five seconds
                later, whatever this is.
              '';
            };

            options.stop = lib.mkOption {
              type = with lib.types; nullOr (functionTo (listOf str));
              default = null;
              description = ''
                Given a username, a command which stops that user's supervisor - run as the
                user when the session ends, in place of signalling.

                Null, the default, means {option}`stopSignal` is enough. Set this where the
                process the launcher owns is not the supervisor and so cannot be asked:
                systemd is the case, where a `systemd --user` is a unit of pid 1's and the
                launcher's child is the `systemctl start --wait` which asked for it. Signalling
                that client says nothing about the job it enqueued; `systemctl stop` is the only
                thing that does.

                The launcher still waits for its own child afterwards, and still escalates to
                SIGKILL - so a stop which stops nothing is bounded rather than a session which
                never ends.
              '';
            };
          };
        };
      };
    };

    user.sessionLauncher = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = launcher;
      defaultText = lib.literalMD "a generated binary";
      description = ''
        What a login session runs instead of running its payload directly:

        ```
        sessionLauncher --user <name> [--session-env <program>] -- <payload> [args...]
        ```

        It starts the payload, runs `--session-env` until it succeeds, exports what that
        printed, starts that user's supervisor with it, and stops the supervisor when the payload
        exits. The payload's exit status is its own.

        `--session-env` is the only compositor-specific part of a graphical session, and is
        supplied by the caller so that nothing here needs to know what a wayland socket is
        called. Succeeding means the session is usable; what it prints, as one `NAME=VALUE` per
        line, is what the session has to tell the tree about itself - `WAYLAND_DISPLAY`, whose
        value the compositor chose after it started and which therefore cannot be inherited.

        A program, executed with no arguments, rather than a command for a shell to evaluate -
        as is every other command this runs. A caller with something to say in shell says it in
        a script, which is what one that had a shell command was already passing: a store path
        is one word either way.
      '';
    };

    users = lib.mkOption {
      default = { };
      description = ''
        Per-user service trees, one per user.

        A user's units are written as if that user were the only thing on the machine, and are
        the only things they may depend on: the supervisor running them is that user's own and
        cannot observe the system's units, so an edge naming one is refused rather than silently
        never satisfied. Anything a tree needs from the system belongs earlier in the trunk,
        where it is up before any session can start.

        These start with a session and stop with it, which is what separates them from a system
        unit that merely runs as a user - {option}`providers.services.units` with `user` set is
        still the way to say that.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          # the session's own environment, as opposed to what the session discovers about
          # itself.
          #
          # Both end up exported by the launcher and the difference is only when.
          # `sessionLauncherEnv` is polled after the payload starts, because what it reports is
          # something the payload had to exist to publish - a compositor's socket name. These
          # are known before anything runs, and have to be set before the payload rather than
          # after it: the payload is what spawns a session's applications, so a variable it does
          # not have is a variable they do not have either.
          #
          # Which is the shape of the bug this exists for. home-manager writes a user's session
          # variables twice - once into a shell file for login shells, once into
          # ~/.config/environment.d for systemd's user manager to import - and on a machine
          # without that manager the second is a file nobody reads. So a terminal's children
          # were themed and the compositor's were not: `QT_QPA_PLATFORMTHEME` reached a Qt
          # application launched from a shell and not one launched from a key binding, which
          # looks like the application ignoring the theme rather than never being told.
          #
          # Per-user because the values are: they are paths into one user's profile, and they
          # change when that user's generation does.
          options.sessionVariables = lib.mkOption {
            # `int` and `path` coerced rather than refused, because home-manager's own session
            # variables are typed that way and a consumer feeding them straight in should not
            # have to map over them first. XCURSOR_SIZE is the one that found this: stylix sets
            # it to 32, an integer, and an attrsOf str refuses it with the value and not the
            # type in the message, which reads like a bad path rather than a number.
            type = lib.types.attrsOf (
              lib.types.coercedTo lib.types.int builtins.toString (
                lib.types.coercedTo lib.types.path builtins.toString lib.types.str
              )
            );
            default = { };
            example = {
              QT_QPA_PLATFORMTHEME = "qt5ct";
            };
            description = ''
              Environment variables for this user's whole session - the payload the launcher
              runs, the supervisor beside it, and everything either of them starts.

              Set before the payload, so that what a compositor spawns inherits them.
              {option}`providers.services.user.sessionLauncherEnv` is for the other case, a
              value only knowable once the session is running.

              Values are expanded by the shell the launcher is, so a variable may extend
              itself the way `environment.d(5)` allows - `$XDG_CONFIG_DIRS` and
              `''${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}` both do what they look like. That is
              also the caveat: a value is shell, so one containing a command substitution
              would run it. They come from the configuration, which is as trusted as the
              launcher itself, but nothing here sanitises them.
            '';
          };

          options.units = lib.mkOption {
            inherit (options.providers.services.units) type;
            default = { };
            description = ''
              This user's units. See {option}`providers.services.units`.
            '';
          };
        }
      );
    };
  };

  config = {
    # what the launcher reads. Only where there is a tree to launch: a machine with no
    # `providers.services.users` has nothing to write and nothing that would read it.
    environment.etc = lib.mkIf (cfg.users != { }) {
      "finix/session-launch".source = launcherConfig;
    };

    # a session variable whose value looks like it expected a shell.
    #
    # The launcher used to be shell and these were expanded by it, so `$XDG_CONFIG_DIRS` in a
    # value extended the variable the way environment.d(5) allows. The binary sets them
    # literally, which is the safer rule and a change in behaviour for anything that relied on
    # the old one - so it is reported rather than left to be discovered as a path with a dollar
    # in it. home-manager's own session variables are the likely source.
    warnings = lib.concatLists (
      lib.mapAttrsToList (
        user: u:
        lib.mapAttrsToList (
          name: _:
          "providers.services.users.${user}.sessionVariables.${name} contains a `$`, which the"
          + " session launcher no longer expands - it is set literally. Compute the value in"
          + " Nix instead."
        ) (lib.filterAttrs (_: value: lib.hasInfix "$" (toString value)) u.sessionVariables)
      ) cfg.users
    );

    assertions = [
      {
        assertion = cfg.users != { } -> cfg.user.manager ? supervisor;
        message =
          if cfg.user.backend == null then
            ''
              providers.services.users declares a tree for ${lib.concatStringsSep ", " (lib.attrNames cfg.users)}, but providers.services.user.backend is not set, so there is nothing to
              supervise them.

              A user's units are run by an instance of an implementation started by their
              session, which is not the same thing as the system's supervisor running a unit as
              a user - name the implementation to serve that scope, or say what you meant with
              providers.services.units and `user`.
            ''
          else
            ''
              providers.services.user.backend is ${cfg.user.backend}, which cannot run as a
              user, so it cannot supervise the tree declared for ${lib.concatStringsSep ", " (lib.attrNames cfg.users)}.

              finit is the case this usually means. It runs a unit as a given user, which is
              what providers.services.units with `user` is for, but a non-PID-1 finit with a
              user's euid exits EX_NOPERM - there is no per-user instance for it to be. Name an
              implementation which has one, or move these units into the system tree and run
              them as the user.
            '';
      }

      {
        assertion = crossTree == [ ];
        message = ''
          These edges leave the user's own tree, and the supervisor running it cannot see
          anything outside:
          ${lib.concatStringsSep "\n" crossTree}

          A user's supervisor is started by their session and knows only the units it was given,
          so a system unit named here is one it will wait for for ever. Depend on another unit of
          the same user, or attach what is being waited for to an earlier trunk level so that it
          is already up before any session begins.
        '';
      }
    ];
  };
}
