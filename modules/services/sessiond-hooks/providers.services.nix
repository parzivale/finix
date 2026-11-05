# how services.sessiond-hooks runs, as providers.services units
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
  cfg = config.services.sessiond-hooks;
  format = pkgs.formats.toml { };
in
{
  config = lib.mkIf cfg.enable {
    # one unit per hook, each its own sessiond-hooks process
    providers.services.units = lib.mapAttrs' (
      name: hook:
      lib.nameValuePair "sessiond-hooks-${name}" {
        inherit (hook) enable;
        description = "sessiond per-user hook: ${name}";

        # a client of sessiond's, over the bus, so it waits for sessiond rather than for a tier
        requires = [ "sessiond" ];

        type.service.command = lib.escapeShellArgs [
          (lib.getExe cfg.package)
          "--log-target"
          "syslog"
          "--config"
          "${format.generate "sessiond-hooks-${name}.toml" hook.settings}"
        ];

        environment = {
          LOG_LEVEL = if cfg.debug then "debug" else lib.mkDefault "info";
        };
      }
    ) cfg.hooks;
  };
}
