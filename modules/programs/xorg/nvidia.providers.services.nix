# the nvidia sideband directory, as a providers.services rule
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.hardware.nvidia;
in
{
  config = lib.mkIf (cfg.enable && config.programs.xorg.enable) {
    providers.services.tmpfiles.rules = [
      # Remove the following log message:
      #    (WW) NVIDIA: Failed to bind sideband socket to
      #    (WW) NVIDIA:     '/var/run/nvidia-xdriver-b4f69129' Permission denied
      #
      # https://bbs.archlinux.org/viewtopic.php?pid=1909115#p1909115
      {
        type = "directory";
        path = "/run/nvidia-xdriver";
        mode = "0770";
        user = "root";
        group = "users";
      }
    ];
  };
}
