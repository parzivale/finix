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

    providers.services.units.gardendevd-settle = {
      description = "trigger device events and wait for gardendevd to settle";

      requires = [
        (lib.head config.providers.services.trunk.levels)
        "gardendevd"
      ];

      type.oneshot.command = pkgs.writeShellScript "gardendevd-settle" ''
        ${cfg.package}/bin/gardendevctl trigger -c add -t all
        ${cfg.package}/bin/gardendevctl settle -t 30
      '';
    };
  };
}
