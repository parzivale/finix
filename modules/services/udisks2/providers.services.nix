# how services.udisks2 runs, as providers.services units
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
  cfg = config.services.udisks2;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.udisks2 = {
      description = "disk manager";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      # `log` is gone with the stanza: finit's own logging, which the contract does not model -
      # every implementation gives a unit's output to its supervisor.
      type.service.command =
        "${cfg.package}/libexec/udisks2/udisksd" + lib.optionalString cfg.debug " --debug";
    };
  };
}
