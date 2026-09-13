# how services.uptime-kuma runs, as providers.services units
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
  cfg = config.services.uptime-kuma;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.uptime-kuma = {
      inherit (cfg) user group;

      description = "uptime kuma";

      requires = [
        "basic"
        "network-online"
      ];

      # `kill = 10` becomes the contract's stopTimeout, which every implementation bounds
      # except runit - and says so.
      stopTimeout = lib.mkDefault 10;

      # uptime-kuma runs ping by name for its monitors
      path = [ pkgs.unixtools.ping ];

      type.service.command = lib.getExe cfg.package;

      environment = cfg.settings;
    };

    providers.services.tmpfiles.rules = lib.optional (cfg.settings.DATA_DIR == "/var/lib/uptime-kuma") {
      type = "directory";
      path = cfg.settings.DATA_DIR;
      mode = "0750";
      inherit (cfg) user group;
    };
  };
}
