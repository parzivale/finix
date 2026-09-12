# how services.polkit runs, as providers.services units
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
  cfg = config.services.polkit;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.polkit = {
      description = "policykit authorization manager";

      # nothing about sessiond: the session and seat managers are in the tier before this one,
      # so anything here is after them. Naming one would also have made it an optional edge,
      # which is the shape that hides a requirement rather than stating it.
      requires = [ "basic" ];

      type.service.command =
        "${cfg.package.out}/lib/polkit-1/polkitd --no-debug "
        + lib.optionalString cfg.debug "--log-level=debug";
    };
  };
}
