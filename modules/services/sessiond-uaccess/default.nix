{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sessiond-uaccess;

  configFile = pkgs.writeTextDir "00-nixos.lua" cfg.extraConfig;

  # gardendevd needs libudev-garden; mdevd/keventd need libudev-zero
  udevApi =
    if config.services.gardendevd.enable then
      pkgs.libudev-garden
    else if config.services.mdevd.enable || config.services.keventd.enable then
      pkgs.libudev-zero
    else
      null;
in
{
  options.services.sessiond-uaccess = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sessiond](${pkgs.sessiond-uaccess.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sessiond-uaccess.override (
        lib.optionalAttrs (udevApi != null) {
          udev = udevApi;
        }
      );
      defaultText = lib.literalExpression "pkgs.sessiond-uaccess";
      description = ''
        The package to use for `sessiond`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        device {
          access = "rw",
          match = function(dev)
            return dev.subsystem == "backlight"
          end,
        }
      '';
      description = ''
        Additional `lua` rules loaded after the packaged `sessiond-uaccess` rules. See [upstream documentation](https://tangled.org/r0chd.pl/sessiond-uaccess/blob/master/rules/70-uaccess.lua)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # this watches sessiond's sessions over the bus and does nothing without it, so it turns
    # it on rather than ordering after a daemon which may not be there - the same thing
    # sessiond itself does with polkit
    services.sessiond.enable = true;

    providers.services.units.sessiond-uaccess = {
      description = "grant device access to active local sessions";

      # sessiond itself, by name: this watches that daemon's sessions, so it is one of the
      # few edges which is genuinely about a particular service rather than about a tier
      requires = [ "sessiond" ];

      type.service.command =
        "${lib.getExe cfg.package} --log-target syslog --rules-dirs ${cfg.package}/share/sessiond-uaccess/rules "
        + lib.optionalString (cfg.extraConfig != "") "--rules-dirs ${configFile}";
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
