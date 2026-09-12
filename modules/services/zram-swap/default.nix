{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.zram-swap;
in
{
  imports = [ ./providers.services.nix ];

  options.services.zram-swap = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable swap on a compressed zram block device.
      '';
    };

    memoryPercent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 50;
      description = ''
        Size of the zram device as a percentage of total memory.

        Must be positive. Values above 100 are allowed because the device
        stores compressed data; actual memory usage depends on compressibility.
      '';
    };

    algorithm = lib.mkOption {
      type = lib.types.str;
      default = "zstd";
      example = "lz4";
      description = ''
        Compression algorithm passed to {command}`zramctl`.
      '';
    };

    priority = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        Swap priority of the zram device. Higher values are preferred by
        the kernel over lower-priority swap devices.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "zram" ];

  };
}
