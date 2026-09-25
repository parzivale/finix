# The firmware blobs a machine needs from linux-firmware and its friends.
#
# finix has `hardware.firmware`, a list of packages whose `/lib/firmware` is unioned and
# handed to both the initrd and the running system. What it has not had is anything which
# fills that list, so a machine whose drivers need blobs - every AMD or Intel GPU, most
# wifi, a lot of bluetooth - had to name the packages itself or go without. Going without
# is not a degraded mode: amdgpu without its microcode does not bind at all, so there is
# no DRM device and nothing which wanted one works.
#
# Ported from nixos, whose spelling of this is what other module trees write into -
# nixos-facter's `firmware.nix` among them. The renamed-option shims are left behind: they
# forward option paths this module tree never had.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware;
in
{
  options = {
    hardware.enableAllFirmware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether to enable all firmware, including
        [unfree packages that must be explicitly allowed](https://nixos.org/manual/nixpkgs/unstable/#sec-allow-unfree).

        Alternatively, use {option}`hardware.enableRedistributableFirmware`.
      '';
    };

    hardware.enableRedistributableFirmware =
      lib.mkEnableOption "firmware with a license allowing redistribution"
      // {
        default = config.hardware.enableAllFirmware;
        defaultText = lib.literalExpression "config.hardware.enableAllFirmware";
      };

    hardware.wirelessRegulatoryDatabase =
      lib.mkEnableOption "loading the wireless regulatory database at boot"
      // {
        default = cfg.enableRedistributableFirmware || cfg.enableAllFirmware;
        defaultText = lib.literalMD ''
          Enabled if firmware is allowed via {option}`hardware.enableRedistributableFirmware`
          or {option}`hardware.enableAllFirmware`.
        '';
      };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enableAllFirmware || cfg.enableRedistributableFirmware) {
      hardware.firmware =
        with pkgs;
        [
          linux-firmware
          ipw2200-firmware
          rtl8192su-firmware
          rt5677-firmware
          rtl8761b-firmware
          zd1211fw
          alsa-firmware
          sof-firmware
          libreelec-dvb-firmware
        ]
        ++ lib.optional pkgs.stdenv.hostPlatform.isAarch raspberrypiWirelessFirmware;
    })

    (lib.mkIf cfg.enableAllFirmware {
      hardware.firmware =
        with pkgs;
        [
          broadcom-bt-firmware
          b43Firmware_5_1_138
          b43Firmware_6_30_163_46
          xone-dongle-firmware
        ]
        ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [
          facetimehd-calibration
          facetimehd-firmware
        ];
    })

    (lib.mkIf cfg.wirelessRegulatoryDatabase {
      hardware.firmware = [ pkgs.wireless-regdb ];
    })
  ];
}
