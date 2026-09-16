# how services.iwd runs, as providers.services units
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
  cfg = config.services.iwd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.iwd = {
      description = "wireless service";
      requires = [ "basic" ];

      # iwd runs resolvconf by name when it has one
      path = lib.optional config.programs.resolvconf.enable config.programs.resolvconf.package;

      # iwd keeps its known networks here, and now starts here too rather than in whatever
      # directory the supervisor happened to leave it in
      stateDirectory."/var/lib/iwd" = "0700";

      # iwd reads /etc/iwd/main.conf from a fixed path and names it nowhere, so without this
      # a changed configuration leaves the daemon running with the one it read at boot. The
      # "standard nixos trick" this replaces was appended to finit.d/iwd.conf, and so reached
      # finit alone.
      reloadTriggers = [ cfg.configFile ];

      type.service.command = "${cfg.package}/libexec/iwd${lib.optionalString cfg.debug " -d"}";
    };

  };
}
