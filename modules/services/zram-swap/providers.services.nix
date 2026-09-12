# how services.zram-swap runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.zram-swap;
in
{
  config = lib.mkIf cfg.enable {
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
