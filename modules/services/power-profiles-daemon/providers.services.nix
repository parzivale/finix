# how services.power-profiles-daemon runs, as providers.services units
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
  cfg = config.services.power-profiles-daemon;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.power-profiles-daemon = {
      description = "power profiles daemon";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      type.service.command = "${cfg.package}/libexec/power-profiles-daemon";
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/power-profiles-daemon";
      }
    ];
  };
}
