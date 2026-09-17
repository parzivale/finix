{
  lib,
  pkgs,
  config,
  modules,
  ...
}:
let
  cfg = config.programs.cosmic-greeter;
  inherit (lib) types;

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
  imports = [
    ./providers.services.nix

    modules.accounts-daemon
    modules.cosmic-comp
    modules.greetd
  ];

  options.programs.cosmic-greeter = {
    enable = lib.mkEnableOption "COSMIC greeter";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.cosmic-greeter.override {
        udev = udevApi;
        libinput = pkgs.libinput.override (
          lib.optionalAttrs (udevApi != null) {
            udev = udevApi;
            wacomSupport = false;
          }
        );
      };
      defaultText = lib.literalExpression "pkgs.cosmic-greeter";
      description = ''
        The package to use for `cosmic-greeter`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    programs.cosmic-comp.enable = true;

    services.accounts-daemon.enable = true;
    services.greetd.enable = true;
    services.greetd.settings.default_session = {
      user = lib.mkForce "cosmic-greeter";
      command = ''${lib.getExe' pkgs.coreutils "env"} XCURSOR_THEME="''${XCURSOR_THEME:-Pop}" ${lib.getExe' cfg.package "cosmic-greeter-start"}'';
    };

    users.groups.cosmic-greeter = { };
    users.users.cosmic-greeter = {
      description = "COSMIC login greeter user";
      isSystemUser = true;
      home = "/var/lib/cosmic-greeter";
      createHome = true;
      group = "cosmic-greeter";
      extraGroups = lib.optionals config.services.seatd.enable [ config.services.seatd.group ];
    };

    services.dbus.packages = [ cfg.package ];

    # Required for screen locker
    security.pam.services.cosmic-greeter = {
      text = config.security.pam.services.login.text;
    };
  };
}
