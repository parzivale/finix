# how programs.modprobe runs, as providers.services units
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
  cfg = config.programs.modprobe;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.modprobe = {
      description = "load the configured kernel modules";

      # the head of the trunk: a driver anything later needs should be in the kernel by the
      # time that thing starts
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      # one at a time, and a module which will not load is reported rather than fatal. As a
      # finit task nothing waited on this, so a missing module was a line in the log; as a
      # unit at the head of the trunk every level above waits for it, and `modprobe -a`
      # returning non-zero for one absent module would hold the entire boot.
      type.oneshot.command = pkgs.writeShellScript "load-kernel-modules" ''
        for module in ${lib.escapeShellArgs config.boot.kernelModules}; do
          ${lib.getExe' pkgs.kmod "modprobe"} -b "$module" ||
            echo "modprobe: $module could not be loaded" >&2
        done
      '';
    };
  };
}
