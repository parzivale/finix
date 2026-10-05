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
  index = pkgs.writeText "initctl-index" (
    lib.concatStrings (
      map (n: "system\t${n}\n") (lib.attrNames enabled)
      ++ lib.concatLists (
        lib.mapAttrsToList (user: tree: map (n: "${user}\t${n}\n") (lib.attrNames tree.units)) userTrees
      )
    )
  );

  # reaching a user's supervisor. One case per user with a tree, because the socket is per-user
  # and the function the backend supplies is what knows how to name it. Empty when no
  # implementation claims the user namespace, which `supported` below accounts for - and which
  # is why the `case` is generated here rather than written out in the script: with no arms
  # there is nothing to dispatch on, and an arm-less `case` is both pointless and, with a
  # catch-all that exits, enough to make the next line unreachable and fail shellcheck.
  userDispatch = lib.optionalString (cfg.user.ctl != null && userTrees != { }) ''
    case "$1" in
      ${lib.concatStrings (
        lib.mapAttrsToList (user: _: ''
          ${user}) ctl=(${cfg.user.ctl user}) ;;
        '') userTrees
      )}
    esac
  '';

  initctl = pkgs.writeShellApplication {
    name = "initctl";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = ''
      index=${index}

      usage() {
        cat >&2 <<'EOF'
      usage: initctl <command> [unit] [--user <name> | --system]

        list                 every unit, in every tree
        status <unit>        one unit's state
        start|stop <unit>    ...
        restart <unit>       stop then start, unless the backend has its own
        reboot|poweroff|halt the machine

      A unit is named on its own and found in your own tree first, then the system's.
      `--system` forces the system tree for a name that is in both; `--user` names
      another user's.
      EOF
        exit 2
      }

      # the tree a name lives in, or a refusal naming the choice to be made.
      #
      # Sets `tree` rather than printing it, because printing meant being called in `$(...)` and
      # a failure there exits the subshell rather than the script: the first version reported
      # "no unit named ..." and then exited 0, which is the wrong answer to give a shell.
      #
      # An unqualified name resolves to the caller's own tree before the system's. A person
      # typing `initctl restart mako` means the mako in their session, and having to say so with
      # `--user` on every command is the thing this tool exists to stop. `--system` forces the
      # other way for a name that exists in both, and `--user` names someone else's.
      resolve() {
        local unit=$1 want=''${2-} where="" cands pref n
        [ -z "$want" ] || where=" in $want"

        cands=$(awk -F'\t' -v u="$unit" -v w="$want" \
          '$2 == u && (w == "" || $1 == w) { print $1 }' "$index")

        if [ -z "$cands" ]; then
          echo "initctl: no unit named '$unit'$where" >&2
          return 1
        fi

        for pref in "$(id -un)" system; do
          if printf '%s\n' "$cands" | grep -qx -- "$pref"; then
            tree=$pref
            return 0
          fi
        done

        n=$(printf '%s\n' "$cands" | wc -l)
        if [ "$n" = 1 ]; then
          tree=$cands
          return 0
        fi

        echo "initctl: '$unit' is in: $(printf '%s' "$cands" | tr '\n' ' ')- name one with --user" >&2
        return 1
      }

      # the command for a tree, as an array: the system's operations take a unit on stdin, a
      # user's supervisor takes a subcommand and a name, so the caller picks which it is.
      #
      # The whole function collapses to the refusal when no implementation claims the user
      # namespace - `userDispatch` is empty then, which the comment on it already says to
      # expect. Written as a lookup rather than a `case` for exactly that reason: a `case`
      # whose only arm is the catch-all, and whose catch-all exits, leaves the line after it
      # unreachable, and `writeShellApplication` runs shellcheck:
      #
      #   In .../bin/initctl line 137:
      #     printf '%s\n' "''${ctl[@]}"
      #     ^-----------------------^ SC2317 (info): Command appears to be unreachable.
      #
      # which fails the build of every configuration that has no user tree - a fresh host
      # being the obvious one, since the user supervisor is rarely the first thing wired up.
      user_ctl() {
        local ctl=()
        ${userDispatch}
        if [ ''${#ctl[@]} -eq 0 ]; then
          echo "initctl: no supervisor for '$1'" >&2
          exit 1
        fi
        printf '%s\n' "''${ctl[@]}"
      }

      # arguments in any order, because the first version only recognised `--user` immediately
      # after the command and silently ignored it anywhere else - so `initctl status nix-daemon
      # --user bella` reported the system unit as though the flag had not been given, which is a
      # worse answer than refusing it.
      cmd=""
      unit=""
      user=""

      while [ $# -gt 0 ]; do
        case "$1" in
          --user)
            user=''${2-}
            [ -n "$user" ] || usage
            shift 2
            ;;
          --system)
            user=system
            shift
            ;;
          -*) usage ;;
          *)
            if [ -z "$cmd" ]; then
              cmd=$1
            elif [ -z "$unit" ]; then
              unit=$1
            else
              usage
            fi
            shift
            ;;
        esac
      done

      [ -n "$cmd" ] || usage

      case "$cmd" in
        list)
          printf '%-10s %-28s %s\n' TREE UNIT STATE
          ${cfg.ctl.status} | while IFS="$(printf '\t')" read -r unit state; do
            printf '%-10s %-28s %s\n' system "$unit" "$state"
          done
          ${lib.optionalString (cfg.user.status != null) (
            lib.concatStrings (
              lib.mapAttrsToList (u: _: ''
                ${cfg.user.status u} | while IFS="$(printf '\t')" read -r unit state; do
                  printf '%-10s %-28s %s\n' ${u} "$unit" "$state"
                done
              '') userTrees
            )
          )}
          ;;

        status|start|stop|restart)
          [ -n "$unit" ] || usage

          resolve "$unit" "$user" || exit 1

          if [ "$tree" = system ]; then
            case "$cmd" in
              status)  ${cfg.ctl.status} | awk -F'\t' -v u="$unit" '$1 == u { print $2 }' ;;
              start)   printf '%s\n' "$unit" | ${sw.activate} ;;
              stop)    printf '%s\n' "$unit" | ${sw.deactivate} ;;
              restart) printf '%s\n' "$unit" | ${sw.deactivate}; printf '%s\n' "$unit" | ${sw.activate} ;;
            esac
          else
            mapfile -t ctl < <(user_ctl "$tree")
            "''${ctl[@]}" "$cmd" "$unit"
          fi
          ;;

        reboot)   exec ${cfg.shutdownCommands.reboot or "false"} ;;
        poweroff) exec ${cfg.shutdownCommands.poweroff or "false"} ;;
        halt)     exec ${cfg.shutdownCommands.halt or "false"} ;;

        *) usage ;;
      esac
    '';
  };
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
