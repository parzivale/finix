# overlayfs
#
# Needs no userspace tools - the kernel does the whole job - but it is built as a module rather
# than into the kernel, so the initrd has to be told to load it. Declaring the filesystem as
# supported is not enough on its own: without the module, `mount -t overlay` fails, and where
# the overlay is /nix/store that means the initrd finds no stage 2 init to switch into and the
# machine reboots in a loop rather than reporting anything.
#
# `enable` defaults to false and is turned on by modules/boot/initrd.nix for any fsType which a
# neededForBoot filesystem actually uses - so declaring an overlay is what pulls the module in,
# and a machine with no overlay carries nothing extra.
{ config, lib, ... }:
{
  options = {
    boot.initrd.supportedFilesystems.overlay = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable support for the `overlay` filesystem in the initial ramdisk.
        '';
      };
    };

    boot.supportedFilesystems.overlay = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable support for the `overlay` filesystem.
        '';
      };
    };
  };

  config = {
    boot.initrd.kernelModules = lib.mkIf config.boot.initrd.supportedFilesystems.overlay.enable [
      "overlay"
    ];

    boot.kernelModules = lib.mkIf config.boot.supportedFilesystems.overlay.enable [ "overlay" ];
  };
}
