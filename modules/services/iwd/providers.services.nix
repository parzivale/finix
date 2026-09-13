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

      # iwd reads /etc/iwd/main.conf, but the unit names the file that was generated from, so
      # that a changed configuration is a changed unit and the daemon is restarted with it.
      # The "standard nixos trick" this replaces was appended to finit.d/iwd.conf - a trick
      # only finit ever fell for, leaving every other init running the old configuration.
      type.service.command = pkgs.writeShellScript "iwd" ''
        # restart trigger: ${cfg.configFile}
        exec ${cfg.package}/libexec/iwd${lib.optionalString cfg.debug " -d"}
      '';
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/iwd";
        mode = "0700";
      }
    ];
  };
}
