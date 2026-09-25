# tiny-dfr, which draws the Touch Bar on Apple laptops and turns taps on it into key events.
#
# The package ships a systemd unit and a udev rules file, and the rules file does two separable
# jobs. The first works here unchanged: `ID_SEAT=seat-touchbar` and `TAG-="master-of-seat"`
# move the Touch Bar's DRM device and its input devices off seat0, which is what stops a
# compositor treating the strip as a second monitor. That is plain udev, and finix runs udev.
#
# The second job does not work here and is not meant to: `TAG+="systemd"` with SYSTEMD_WANTS
# and SYSTEMD_ALIAS is device-based activation, so upstream the daemon is started by the
# Touch Bar appearing and bound to it disappearing. Nothing reads those tags here, so the
# daemon is an ordinary unit instead - started once the system is up, by which point udev has
# long since settled, and restarted by the supervisor if the device goes away and comes back.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tiny-dfr;
  format = pkgs.formats.toml { };
  configFile = format.generate "config.toml" cfg.settings;
in
{
  imports = [ ./providers.services.nix ];

  options.services.tiny-dfr = {
    enable = lib.mkEnableOption "tiny-dfr, a Touch Bar daemon for Apple laptops";

    package = lib.mkPackageOption pkgs "tiny-dfr" { };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        Configuration for tiny-dfr, rendered to `/etc/tiny-dfr/config.toml`. See
        [the example configuration](https://github.com/WhatAmISupposedToPutHere/tiny-dfr/blob/master/share/tiny-dfr/config.toml)
        for what it takes.

        Icons named here are looked up in `/etc/tiny-dfr` before the package's own share
        directory, so a button can be given an icon of its own by writing the file there
        through {option}`environment.etc`.
      '';
      example = lib.literalExpression ''
        {
          MediaLayerDefault = true;
          ShowButtonOutlines = false;
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The seat assignment, and the usb configuration switch for the T2 bridge. nixos gets this
    # the same way - `services.udev.packages` - and finix's udev module scans a package's
    # `lib/udev/rules.d` just as nixos' does.
    services.udev.packages = [ cfg.package ];

    environment.etc."tiny-dfr/config.toml".source = configFile;
  };
}
