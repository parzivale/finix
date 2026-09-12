# how programs.ifupdown-ng runs, as providers.services units
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
  cfg = config.programs.ifupdown-ng;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.ifupdown-ng = {
      description = "bring up network interfaces";

      # `sysinit` puts it in the basic tier: the device manager has settled in the tier before,
      # so the interfaces exist, and syslogd is there too - which is what the old
      # `service/syslogd/ready` condition said and no longer needs saying.
      requires = [ "sysinit" ];

      type.oneshot.command = pkgs.writeShellScript "ifup" ''
        ${lib.concatMapStrings (iface: ''
          # `net/${iface}/exist` was a finit netlink condition, which nothing else has. The
          # portable form of the same question is whether the kernel has made the directory.
          #
          # Bounded, and deliberately: an unsatisfied finit condition meant the task simply
          # never ran and the boot carried on, but a unit attached to a tier is something the
          # tier waits for - so an unbounded wait for a NIC which is not present would stall
          # the boot rather than skip the interface.
          for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 100); do
            [ -d /sys/class/net/${iface} ] && break
            ${lib.getExe' pkgs.coreutils "sleep"} 0.1
          done
        '') cfg.auto}
        exec ${cfg.package}/bin/ifup -E ${cfg.package}/libexec/ifupdown-ng ${lib.escapeShellArgs cfg.extraArgs}
      '';
    };

    providers.services.units.ifupdown-ng-down = {
      description = "bring down network interfaces";
      requires = [ "stopped" ];

      type.oneshot.command = pkgs.writeShellScript "ifdown" ''
        ${cfg.package}/bin/ifdown -E ${cfg.package}/libexec/ifupdown-ng ${lib.escapeShellArgs cfg.extraArgs}
      '';
    };
  };
}
