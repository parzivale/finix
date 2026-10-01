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

  # the arms of the launcher's `case`: one per user with a tree, naming what supervises it.
  #
  # baked in rather than passed as an argument so that a session names a user and nothing else.
  # what runs their tree is the implementation's business, and a session that had to spell it out
  # would be naming a backend - which is the one thing a `providers` consumer never does.
  supervisorArms = lib.concatMapStrings (user: ''
    ${user})
      ${cfg.user.manager.supervisor.command user} &
      supervisor=$!
      ;;
  '') (if cfg.user.manager ? supervisor then lib.attrNames cfg.users else [ ]);

  # the same shape as `supervisorArms`, for the variables a session is given rather than the
  # thing that supervises it.
  #
  # `lib.toShellVars` renders an attrset as assignments with values quoted, which is nearly what
  # is wanted and not quite: a value is allowed to refer to the variable it is replacing, the way
  # `environment.d(5)` lets one extend a path, and `toShellVars` quotes in a way that would
  # export the text rather than the result.
  #
  # Double quotes rather than none, though. Parameter expansion happens inside them, so
  # `''${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}` still extends the variable - what they prevent is
  # word splitting, and unquoted a value with a space in it becomes two arguments to `export`,
  # the second of them a bare word. Store paths do not have spaces in them; values arriving here
  # are not all store paths.
  sessionVariableArms = lib.concatMapStrings (
    user:
    let
      vars = cfg.users.${user}.sessionVariables;
    in
    lib.optionalString (vars != { }) ''
      ${user})
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "    export ${name}=\"${value}\"") vars
      )}
        ;;
    ''
  ) (lib.attrNames cfg.users);

  launcher = pkgs.writeShellScript "session-launch" ''
    set -eu

    user=
    sessionEnv=

    while [ "$#" -gt 0 ]; do
      case "$1" in
        --user)  user="$2";  shift 2 ;;
        --session-env) sessionEnv="$2"; shift 2 ;;
        --)      shift; break ;;
        *) echo "session-launch: unrecognised argument $1" >&2; exit 2 ;;
      esac
    done

    [ -n "$user" ] || { echo "session-launch: --user is required" >&2; exit 2; }
    [ "$#" -gt 0 ] || { echo "session-launch: nothing to run" >&2; exit 2; }

    # the session's environment, before anything in the session exists.
    #
    # Before the payload and not after it, unlike the block below: the payload is what spawns a
    # session's applications, so anything it is not told it cannot pass on. Setting these
    # afterwards would reach the supervisor and miss everything the compositor starts, which is
    # the half that was already broken.
    ${lib.optionalString (sessionVariableArms != "") ''
      case "$user" in
      ${sessionVariableArms}
        *) ;;
      esac
    ''}

    # the payload - a compositor, a shell, whatever the session is - in the background, because
    # this process has to outlive it by long enough to stop the supervisor.
    "$@" &
    payload=$!

    # the payload is running but may not yet be usable, and what makes it usable is often also
    # what has to be told to the tree: a wayland compositor binds a socket whose name it chose,
    # and every client needs to be told which one.
    #
    # both from one command, because they are one fact. `--session-env` is polled until it
    # succeeds - that is readiness - and what it prints is exported here before the supervisor
    # starts. a compositor with nothing to publish prints nothing and is a readiness check.
    #
    # it has to be this way round rather than the payload exporting for itself: the payload is a
    # child of this process, so nothing it sets can reach back here, and a sibling started
    # afterwards would not see it either. that is the one thing inheritance cannot do, and the
    # reason systemd has `import-environment` at all. this is that, as one command supplied by
    # whoever knows what the session publishes.
    #
    # unbounded, unlike the system unit this replaces: there, nothing else knew whether a session
    # was ever coming, so waiting forever meant a machine stuck with no way to say why, and a
    # deadline was the only honest answer. here the payload is this process's own child, so the
    # wait ends when it exits whether or not it ever became ready. what a deadline would add is a
    # report, so that is what the warning is.
    if [ -n "$sessionEnv" ]; then
      waited=0
      until published=$(${lib.getExe pkgs.bashNonInteractive} -c "$sessionEnv" 2>/dev/null); do
        if ! kill -0 "$payload" 2>/dev/null; then
          set +e; wait "$payload"; status=$?; set -e
          echo "session-launch: $1 exited before the session was ready" >&2
          exit "$status"
        fi

        ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        waited=$((waited + 1))

        if [ "$waited" = 300 ]; then
          echo "session-launch: still waiting for the session after 30s" >&2
        fi
      done

      # one NAME=VALUE per line. `export` a line at a time rather than `export $(...)`, which
      # would split a value containing a space into arguments of its own.
      while IFS= read -r assignment; do
        [ -n "$assignment" ] || continue
        export "$assignment"
      done <<EOF
    $published
    EOF
    fi

    # the supervisor, started here and so a child of the session: it inherits XDG_RUNTIME_DIR,
    # DBUS_SESSION_BUS_ADDRESS and whatever the payload published into this environment, and
    # every unit it starts inherits them in turn. that inheritance is the entire mechanism.
    #
    # ordered after the readiness check for the same reason: a variable the payload sets on
    # becoming ready is in this environment by now, and would not have been a moment earlier.
    supervisor=
    case "$user" in
      ${supervisorArms}
      *) echo "session-launch: no service tree is declared for $user" >&2 ;;
    esac

    # one session per user is assumed rather than enforced. two would put two supervisors on the
    # same XDG_RUNTIME_DIR, and their trees would contend for the sockets in it - two sound
    # servers on one `pipewire-0`. refusing the second, or reference-counting so that the first
    # session starts the tree and the last stops it, both belong here when it matters.

    set +e
    wait "$payload"
    status=$?
    set -e

    # the session is over, so the tree goes with it. this is the half a supervisor started at
    # boot cannot do at all: nothing tells it that a session ended, so its units simply keep
    # running with nothing to serve.
    if [ -n "$supervisor" ]; then
      kill -TERM "$supervisor" 2>/dev/null || :

      waited=0
      while kill -0 "$supervisor" 2>/dev/null && [ "$waited" -lt 50 ]; do
        ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        waited=$((waited + 1))
      done

      kill -KILL "$supervisor" 2>/dev/null || :
    fi

    exit "$status"
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
              type = lib.types.functionTo lib.types.str;
              description = ''
                Given a username, the invocation which supervises that user's units.

                It is run by {option}`providers.services.user.sessionLauncher`, as the user,
                inside their session - so it inherits that session's environment, and must not
                daemonise away from it.
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
      defaultText = lib.literalMD "a generated script";
      description = ''
        What a login session runs instead of running its payload directly:

        ```
        sessionLauncher --user <name> [--session-env <command>] -- <payload> [args...]
        ```

        It starts the payload, polls `--session-env` until it succeeds, exports what that
        printed, starts that user's supervisor with it, and stops the supervisor when the payload
        exits. The payload's exit status is its own.

        `--session-env` is the only compositor-specific part of a graphical session, and is
        supplied by the caller so that nothing here needs to know what a wayland socket is
        called. Succeeding means the session is usable; what it prints, as one `NAME=VALUE` per
        line, is what the session has to tell the tree about itself - `WAYLAND_DISPLAY`, whose
        value the compositor chose after it started and which therefore cannot be inherited.
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
