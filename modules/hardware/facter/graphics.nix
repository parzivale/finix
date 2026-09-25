{ lib, config, ... }:
let
  facterLib = import ./lib.nix lib;
  cfg = config.hardware.facter.detected.graphics;
in
{
  options.hardware.facter.detected = {
    graphics.enable = lib.mkEnableOption "Enable the Graphics module" // {
      default = builtins.length (config.hardware.facter.report.hardware.monitor or [ ]) > 0;
      defaultText = "hardware dependent";
    };

    boot.graphics.kernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # nouveau is left out deliberately upstream, in case the proprietary nvidia driver is
      # wanted instead - a report cannot tell which, and loading nouveau decides it.
      default = lib.remove "nouveau" (
        lib.uniqueStrings (
          facterLib.collectDrivers (config.hardware.facter.report.hardware.graphics_card or [ ])
        )
      );
      defaultText = "hardware dependent";
      description = ''
        List of kernel modules to load at boot for the graphics card.
      '';
    };
  };

  # nixos' version forks here on `lib.version`, to write `hardware.opengl` on releases before
  # 24.11. There is one spelling to write here, so there is no fork.
  config = lib.mkIf (config.hardware.facter.enable && cfg.enable) {
    boot.initrd.kernelModules = config.hardware.facter.detected.boot.graphics.kernelModules;
    hardware.graphics.enable = lib.mkDefault true;
  };
}
