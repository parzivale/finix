# how services.gardendevd runs, as providers.services units
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
  cfg = config.services.gardendevd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.gardendevd = {
      description = "device event daemon (gardendevd)";

      # the head tier, beside the other device managers, so `sysinit` waits for device events
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      # the rules gardendevd runs invoke helpers by name. Every implementation gives a unit a
      # PATH now, dinit's is scripted in by its backend, so this says what it wants and no more.
      inherit (cfg) path;

      type.service = {
        command = "${cfg.package}/bin/gardendevd " + lib.escapeShellArgs cfg.extraArgs;

        # what the daemon can do, best first. The contract takes the best of these the
        # implementation can observe; `fork` last is what makes that always resolvable.
        #
        # `gardendevd --help`: `-D <fd>  Readiness notification file descriptor`. Which
        # descriptor is the implementation's business, and it appends it.
        readiness = [
          { s6.flag = "-D"; }
          "fork"
        ];
      };
    };

    # the trigger and the settle, split the way udev's are and for the same reason.
    #
    # These were one unit on the head of the trunk, so `sysinit` waited for the whole device
    # queue to drain before the rest of the boot could proceed. That is the cost udev paid too,
    # but here it was worse than slow: a rule whose helper never returns - the zfs package's
    # rules are on every machine with zfs enabled - holds the settle, the settle held `sysinit`,
    # and the boot stopped after the head tier with nothing on the console to say why.
    #
    # `gardendevctl trigger` only queues the events, so the coldplug stays on the head of the
    # trunk, where devices have to start appearing, and costs nothing to wait for.
    providers.services.units.gardendevd-coldplug = {
      description = "trigger coldplug events";

      requires = [
        (lib.head config.providers.services.trunk.levels)
        "gardendevd"
      ];

      type.oneshot.command = "${cfg.package}/bin/gardendevctl trigger -c add -t all";
    };

    # and the wait, attached to no tier.
    #
    # `requires` names no trunk level, so no barrier waits for this: it runs for whoever asks for
    # it by name. That is the few consumers which want "enumeration is finished" as a global
    # property - ifupdown-ng waiting out interface renames, keyd grabbing every keyboard - and
    # which name it already. Anything else wants `type.service.readiness.waitFor.path`; see
    # udev's `udev-settle` for the longer argument.
    providers.services.units.gardendevd-settle = {
      description = "wait for the device queue to drain";

      requires = [ "gardendevd-coldplug" ];

      type.oneshot.command = "${cfg.package}/bin/gardendevctl settle -t 30";
    };
  };
}
