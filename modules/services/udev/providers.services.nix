# how services.udev runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.udev;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.udevd = {
      description = "device event daemon (${cfg.package.pname})";

      type.service = {
        # `--ready-notify=%n` is gone with the finit stanza: %n is finit substituting the
        # descriptor it chose, which no other init has an equivalent for. Readiness is the
        # daemon being up, and the coldplug unit below waits for it to answer rather than
        # trusting the moment it was spawned.
        command = "${cfg.package}/bin/udevd" + lib.optionalString cfg.debug " -D";
        readiness = "fork";
      };

      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };

    # the trigger, which has to happen and is quick, and the wait, which does not and is not.
    #
    # These were one unit on the head of the trunk, so `sysinit` waited for the whole device
    # tree to settle before anything else in the boot could proceed. On a laptop with 1319
    # devices under /sys that is about two seconds, and it is two seconds nothing overlaps:
    # every other unit in that tier finished inside one.
    #
    # Splitting them is what lets the rest of the boot proceed. `udevadm trigger` only queues
    # the events - it returns as soon as the kernel has been asked - so the coldplug stays on
    # the head of the trunk where it belongs, and costs nothing to wait for. The settle is what
    # takes the time, and almost nothing actually needs it.
    providers.services.units.udev-coldplug = {
      description = "trigger coldplug events";

      requires = [
        (lib.head config.providers.services.trunk.levels)
        "udevd"
      ];

      # It needs no logging of its own: udevadm reports to its supervisor, not to /dev/log.
      type.oneshot.command = pkgs.writeShellScript "udev-coldplug" ''
        # udevd is "ready" as soon as it has forked, which is before its control socket
        # exists. The first thing wanting to talk to it therefore waits for an answer.
        until ${cfg.package}/bin/udevadm control --reload 2>/dev/null; do
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        ${cfg.package}/bin/udevadm trigger -c add -t devices
        ${cfg.package}/bin/udevadm trigger -c add -t subsystems
      '';
    };

    # and the wait, attached to no tier.
    #
    # This was on the head of the trunk, so `sysinit` waited for the whole device tree to drain
    # before the rest of the boot could proceed - about two seconds on a laptop with 1319
    # devices under /sys, in which nothing else happened; every other unit in that tier finished
    # inside one. What it bought was an implicit guarantee that anything in a later tier had
    # device nodes without saying so, which is a dependency nobody wrote down.
    #
    # `requires` names no trunk level, so no barrier waits for this: it runs for whoever asks
    # for it by name. Most consumers should not. A daemon which subscribes to udev events
    # handles a device appearing late by construction, and one which looks once for a known path
    # wants `type.service.readiness.waitFor.path`, which says which device and is observable by
    # every implementation of this contract rather than naming udev.
    #
    # It exists because some consumers genuinely want the global property and there is no
    # per-device way to express it. Interface renaming is the clearest: `ifupdown-ng` is waiting
    # for `wlan0` to have become `wlp1s0f0`, and what it needs to know is that no further
    # renames are coming - which is the absence of an event, not the presence of a path. keyd
    # grabbing every input device is the same shape. Deleting this and leaving those modules to
    # poll something was tried first and is worse: it replaces one honest wait with several
    # guesses.
    providers.services.units.udev-settle = {
      description = "wait for the device queue to drain";

      requires = [ "udev-coldplug" ];

      type.oneshot.command = "${cfg.package}/bin/udevadm settle -t 30";
    };
  };
}
