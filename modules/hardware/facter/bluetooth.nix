{ lib, config, ... }:
{
  options.hardware.facter.detected.bluetooth.enable =
    lib.mkEnableOption "Enable the Facter bluetooth module"
    // {
      default = builtins.length (config.hardware.facter.report.hardware.bluetooth or [ ]) > 0;
      defaultText = "hardware dependent";
    };

  # nixos spells this `hardware.bluetooth.enable`; here the daemon is a service like any
  # other and the option sits under `services`. Same bluez, same enable, different path.
  config.services.bluetooth.enable = lib.mkIf config.hardware.facter.detected.bluetooth.enable (
    lib.mkDefault true
  );
}
