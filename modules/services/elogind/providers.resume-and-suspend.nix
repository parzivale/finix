# elogind as the implementation of the `providers.resumeAndSuspend` contract.
#
# elogind has two sleep-hook directories compiled into it, and `/etc/elogind/system-sleep` is
# the one a configuration can write to. Every executable there is run twice per sleep cycle -
# `pre <kind>` before the machine goes down, `post <kind>` after it comes back - which is the
# protocol systemd's `system-sleep` hooks use, so this is the same shape both sides of the
# fence.
#
# The contract's three events map onto those two calls rather than onto three of their own:
# `suspend` and `hibernate` are both `pre`, told apart by the kind in `$2`, and `resume` is
# `post` regardless of which one it is waking from. That asymmetry is the kernel's - there is
# no separate notification for coming back from a hibernate - and it is why a resume hook
# which needs to know should read `$2` itself.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.elogind;

  enabled = lib.filterAttrs (_: hook: hook.enable) config.providers.resumeAndSuspend.hooks;

  # Ordered by the priority the contract gives each hook, then by name, so that two hooks at
  # the same priority land in a defined order rather than whatever attribute order happens to
  # be. One script for all of them: elogind runs the directory's entries in filename order and
  # gives no way to order them beyond that, so ordering is done here where it can be exact.
  ordered = lib.sort (
    a: b: if a.priority != b.priority then a.priority < b.priority else a.name < b.name
  ) (lib.mapAttrsToList (name: hook: hook // { inherit name; }) enabled);

  section =
    event:
    lib.concatMapStrings (hook: ''

      # ${hook.name} (priority ${toString hook.priority})
      ${hook.action}
    '') (lib.filter (hook: hook.event == event) ordered);

  sleepHook = pkgs.writeShellScript "elogind-system-sleep" ''
    # Deliberately not `set -e`: these hooks belong to different things which happen to run at
    # the same moment, and one of them failing is not a reason to skip the rest. A hook which
    # wants to stop on an error can say so itself.
    set -u

    case "$1" in
      pre)
        case "$2" in
          hibernate|hybrid-sleep)
            ${section "hibernate"}
            ;;
        esac
        ${section "suspend"}
        ;;

      post)
        ${section "resume"}
        ;;
    esac

    exit 0
  '';
in
{
  options.providers.resumeAndSuspend = {
    backend = lib.mkOption {
      type = lib.types.enum [ "elogind" ];
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      providers.resumeAndSuspend.backend = lib.mkDefault "elogind";
    })

    (lib.mkIf (config.providers.resumeAndSuspend.backend == "elogind" && enabled != { }) {
      assertions = [
        {
          assertion = cfg.enable;
          message = ''
            providers.resumeAndSuspend.backend is "elogind", and elogind is not enabled - so
            nothing would run the ${toString (lib.length ordered)} hook(s) defined in
            providers.resumeAndSuspend.hooks.
          '';
        }
      ];

      environment.etc."elogind/system-sleep/hooks" = {
        source = sleepHook;
        mode = "0755";
      };
    })
  ];
}
