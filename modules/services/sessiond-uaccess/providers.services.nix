# how services.sessiond-uaccess runs, as providers.services units
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
  cfg = config.services.sessiond-uaccess;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sessiond-uaccess = {
      description = "grant device access to active local sessions";

      # sessiond itself, by name: this watches that daemon's sessions, so it is one of the
      # few edges which is genuinely about a particular service rather than about a tier
      requires = [ "sessiond" ];

      type.service.command =
        "${lib.getExe cfg.package} --log-target syslog --rules-dirs ${cfg.package}/share/sessiond-uaccess/rules "
        + lib.optionalString (cfg.extraConfig != "") "--rules-dirs ${cfg.configFile}";
      environment =
        if cfg.debug then
          {
            LOG_LEVEL = "debug";
          }
        else
          {
            LOG_LEVEL = lib.mkDefault "info";
          };
    };
  };
}
