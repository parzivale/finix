{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.upower;

  format = pkgs.formats.ini { };
in
{
  options.services.upower = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [upower](${pkgs.upower.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.upower;
      defaultText = lib.literalExpression "pkgs.upower";
      description = ''
        The package to use for `upower`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;
      };
      default = { };
      description = ''
        `upower` configuration. See [upstream documentation](https://gitlab.freedesktop.org/upower/upower/-/blob/master/etc/UPower.conf)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    providers.services.units.upower = {
      description = "daemon for power management";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      type.service.command = "${cfg.package}/libexec/upowerd";
    };

    environment.etc."UPower/UPower.conf".source = format.generate "UPower.conf" cfg.settings;
  };
}
