# how services.tzupdate runs, as providers.services units
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
  cfg = config.services.tzupdate;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.tzupdate = {
      description = "timezone update service";

      # it asks the network where it is, so it waits for one. syslogd is in the head tier and
      # needs no naming.
      requires = [
        "basic"
        "network-online"
      ];

      type.oneshot.command = "${cfg.package}/bin/tzupdate -z ${pkgs.tzdata}/share/zoneinfo -d /dev/null";

      environment = {
        RUST_LOG = lib.mkIf cfg.debug "debug";
      };
    };
  };
}
