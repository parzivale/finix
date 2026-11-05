# how services.sessiond-power runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.sessiond-power;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sessiond-power = {
      description = "Power action handler for sessiond";

      # a client of sessiond's, over the bus, so it waits for sessiond rather than for a tier
      requires = [ "sessiond" ];

      type.service.command = "${lib.getExe cfg.package} --config ${cfg.configFile} --log-target syslog";

      environment = {
        LOG_LEVEL = if cfg.debug then "debug" else lib.mkDefault "info";
      };
    };
  };
}
