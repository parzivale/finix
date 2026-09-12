# how services.thermald runs, as providers.services units
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
  cfg = config.services.thermald;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.thermald = {
      description = "thermal daemon service";

      # nothing about syslogd: it is in the head tier, so anything here is after it
      requires = [ "basic" ];

      type.service.command = "${lib.getExe cfg.package} " + lib.escapeShellArgs cfg.extraArgs;
    };
  };
}
