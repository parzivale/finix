# how services.networkmanager runs, as providers.services units
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
  cfg = config.services.networkmanager;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.network-manager = {
      description = "network manager service";

      # the bus and its socket gate are in the head tier, so `service/dbus/ready` is behind
      # this without being named
      requires = [ "basic" ];

      type.service = {
        command = "${cfg.package}/bin/NetworkManager -n";

        # NetworkManager rereads its configuration on SIGHUP, which is what the commented-out
        # "reload trigger" in the generated finit stanza was reaching for. A switch which only
        # changed 00-nixos.conf now keeps the interfaces up instead of taking the network down
        # and bringing it back.
        reload = "${lib.getExe' pkgs.procps "pkill"} -HUP -x NetworkManager";
      };
    };
  };
}
