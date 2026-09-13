# how services.nvidia-persistenced runs, as providers.services units
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
  cfg = config.services.nvidia-persistenced;
  runtimeDir = "/var/run/nvidia-persistenced";

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.nvidia-persistenced = {
      inherit (cfg) user group;

      description = "NVIDIA persistence daemon";
      requires = [ "basic" ];

      type.service = {
        command = "${lib.getExe cfg.package} " + lib.escapeShellArgs cfg.extraArgs;

        # deliberately not a list ending in `fork`. This daemon forks and the process which was
        # spawned exits - which finit and dinit watch natively, and which runsv and
        # s6-supervise read as a crash and restart forever. Offering `fork` as a fallback would
        # trade a build-time refusal for a restart loop on the machine, so the contract is left
        # to refuse it where it cannot work.
        readiness.waitFor.pidfile.file = "${runtimeDir}/nvidia-persistenced.pid";
      };
    };

    providers.services.units.nvidia-persistenced-cleanup = {
      description = "clear the NVIDIA persistence daemon's runtime directory";
      requires = [ "stopped" ];

      type.oneshot.command = pkgs.writeShellScript "nvidia-persistenced-cleanup" ''
        ${lib.getExe pkgs.findutils} ${runtimeDir} -mindepth 1 -delete
      '';
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = runtimeDir;
        mode = "0750";
        inherit (cfg) user group;
      }
    ];
  };
}
