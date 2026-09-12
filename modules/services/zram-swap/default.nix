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

    providers.services.units.zram-swap = {
      description = "zram swap (${toString cfg.memoryPercent}% RAM, ${cfg.algorithm})";

      # swap belongs early, before the tier which completes `basic`. `task/modprobe/success`
      # named a finit task of finit's own; the module is always present, so what this actually
      # waits on is the kernel module being loadable, which `zramctl` does for itself.
      requires = [ "sysinit" ];

      path = [
        pkgs.coreutils
        pkgs.util-linux
        pkgs.gnugrep
        pkgs.gawk
      ];

      type.oneshot.command = pkgs.writeShellScript "zram-swap" ''
        set -eu
        grep -q zram /proc/swaps && exit 0
        mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        dev=$(zramctl --find --size "$((mem_kb * ${toString cfg.memoryPercent} / 100))K" --algorithm ${cfg.algorithm})
        mkswap "$dev" >/dev/null
        swapon -p ${toString cfg.priority} "$dev"
      '';
    };
  };
}
