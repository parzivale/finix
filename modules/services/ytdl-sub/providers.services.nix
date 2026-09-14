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

    providers.services.tmpfiles.rules =
      let
        owned = path: {
          inherit path;
          type.directory = {
            mode = "0750";
            inherit (cfg) user group;
          };
        };
      in
      lib.optional (cfg.settings.configuration.persist_logs.logs_directory == "/var/log/ytdl-sub") (
        owned "/var/log/ytdl-sub"
      )
      ++ lib.optional (cfg.settings.configuration.working_directory == "/run/ytdl-sub") (
        owned "/run/ytdl-sub"
      )
      ++ lib.optional (cfg.settings.configuration.lock_directory == "/run/lock/ytdl-sub") (
        owned "/run/lock/ytdl-sub"
      );
  };
}
