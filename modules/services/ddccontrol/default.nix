{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.ddccontrol;
in
{
  options.services.ddccontrol = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [ddccontrol](${pkgs.ddccontrol.meta.homepage}) as a system service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [
      "ddcci_backlight"
    ];

    hardware.i2c.enable = true;

    environment.systemPackages = [
      pkgs.ddccontrol
    ];

    services.dbus.enable = true;
    services.dbus.packages = [
      pkgs.ddccontrol
    ];

    providers.services.units.ddccontrol = {
      description = "control monitor parameters, like brightness, contrast, and other...";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      type.service.command = "${pkgs.ddccontrol}/libexec/ddccontrol/ddccontrol_service";
    };
  };
}
