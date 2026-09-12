# how services.ytdl-sub runs, as providers.services units
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
  cfg = config.services.ytdl-sub;
in
{
  config = lib.mkIf cfg.enable {

    providers.scheduler.tasks = {
      ytdl-sub = {
        inherit (cfg) interval user;
        command = "${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs} sub ${cfg.format.generate "subscriptions.yaml" cfg.subscriptions}";
      };
    };
  };
}
