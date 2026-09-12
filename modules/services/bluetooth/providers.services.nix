# how services.bluetooth runs, as providers.services units
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
  cfg = config.services.bluetooth;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.bluetooth = {
      description = "bluetooth service";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      type.service.command =
        "${cfg.package}/libexec/bluetooth/bluetoothd -f /etc/bluetooth/main.conf"
        + lib.optionalString cfg.debug " -d";
    };
  };
}
