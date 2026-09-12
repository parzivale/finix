{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.iwd;
  format = pkgs.formats.ini { };

  configFile = format.generate "main.conf" cfg.settings;
in
{
  options.services.iwd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [iwd](${pkgs.iwd.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.iwd;
      defaultText = lib.literalExpression "pkgs.iwd";
      description = ''
        The package to use for `iwd`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `iwd` configuration. See {manpage}`iwd.config(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.iwd.settings = {
      General = {
        # upstream defaults this to false, expecting another service to own IP.
        # default it on so iwd works standalone, but let users hand IP
        # configuration to a dhcp client instead.
        EnableNetworkConfiguration = lib.mkDefault true;
      };

      Network = {
        NameResolvingService = if config.programs.resolvconf.enable then "resolvconf" else "none";
      };
    };

    environment.systemPackages = [ cfg.package ];
    environment.etc."iwd/main.conf".source = configFile;

    services.dbus.packages = [ cfg.package ];

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/iwd";
        mode = "0700";
      }
    ];

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
        # restart trigger: ${configFile}
        exec ${cfg.package}/libexec/iwd${lib.optionalString cfg.debug " -d"}
      '';
    };
  };
}
