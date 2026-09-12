{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.illum;

  # gardendevd needs libudev-garden; mdevd needs libudev-zero
  udevApi =
    if config.services.gardendevd.enable then
      pkgs.libudev-garden
    else if config.services.mdevd.enable then
      pkgs.libudev-zero
    else
      null;
in
{
  options.services.illum = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [illum](${pkgs.illum.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.illum.override (
        lib.optionalAttrs (udevApi != null) {
          udev = udevApi;
        }
      );
      defaultText = lib.literalExpression "pkgs.illum";
      description = ''
        The package to use for `illum`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    providers.services.units.illum = {
      description = "backlight adjustment service";

      # nothing about syslogd: it is in the head tier, so anything here is after it
      requires = [ "basic" ];

      type.service.command = lib.getExe cfg.package;
    };
  };
}
