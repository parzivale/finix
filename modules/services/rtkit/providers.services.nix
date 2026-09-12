# how services.rtkit runs, as providers.services units
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
  cfg = config.services.rtkit;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.rtkit-daemon = {
      description = "RealtimeKit scheduling policy service";

      # polkit is named because it is a sibling in this tier - a tier orders a unit against
      # everything before it and says nothing about what sits beside it. `nohup` and `cgroup`
      # are gone with the stanza: finit's own process handling, which the contract does not
      # model and no other implementation would honour.
      requires = [
        "basic"
        "polkit"
      ];

      type.service.command =
        "${cfg.package}/libexec/rtkit-daemon" + lib.optionalString cfg.debug " --debug";
    };
  };
}
