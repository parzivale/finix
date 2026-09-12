# how services.fprintd runs, as providers.services units
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
  cfg = config.services.fprintd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.fprintd = {
      description = "fingerprint authentication daemon";

      requires = [
        "basic"
        "polkit"
      ];

      type.service.command = "${cfg.package}/libexec/fprintd --no-timeout";

      environment = {
        G_MESSAGES_DEBUG = lib.mkIf cfg.debug "all";
      };
    };
  };
}
