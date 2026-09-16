# how services.cron runs, as providers.services units
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
  cfg = config.services.cron;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.cron = {
      description = "cron daemon";
      requires = [ "basic" ];

      # read from a fixed path and named nowhere else, so a changed configuration
      # would otherwise leave the daemon running with the old one
      reloadTriggers = [ cfg.crontabFile ];

      type.service = {
        # `-n` is foreground, so ready-on-fork is the only honest answer - see atd for why
        # `notify = "pid"` does not carry over.
        #
        # cron reads /etc/crontab, but the unit names the file that was generated from, so a
        # changed crontab is a changed unit and the daemon is restarted with it. The "standard
        # nixos trick" this replaces was appended to finit.d/cron.conf - a trick only finit
        # ever fell for, which left every other init running yesterday's schedule.
        #
        # A restart, and not a `reload`, for two reasons worth writing down because both are
        # easy to assume the other way round:
        #
        #   - cronie's SIGHUP only reopens its log. The database reload is `load_database()`,
        #     which the scan calls; the signal does not.
        #   - cronie does notice a crontab changing on its own, by mtime and by inotify - but
        #     the mtime half cannot work here. Every file in the store carries the same mtime,
        #     so a new /etc/crontab is not a newer one.
        command = "${lib.getExe cfg.package} -n ${lib.escapeShellArgs cfg.extraArgs}";
        readiness = "fork";
      };
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/cron";
        type.directory.mode = "0710";
      }
      {
        path = "/var/spool";
        type.directory.mode = "0755";
      }
      {
        path = "/var/spool/cron";
        type.directory.mode = "0755";
      }

      # ensure this directory exists - cronie complains if it doesn't
      {
        type = "directory";
        path = "/etc/cron.d";
      }
    ];
  };
}
