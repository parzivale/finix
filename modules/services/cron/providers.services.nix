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

      type.service = {
        # `-n` is foreground, so ready-on-fork is the only honest answer - see atd for why
        # `notify = "pid"` does not carry over.
        #
        # cron reads /etc/crontab, but the unit names the file that was generated from, so a
        # changed crontab is a changed unit and the daemon is restarted with it. The "standard
        # nixos trick" this replaces was appended to finit.d/cron.conf - a trick only finit
        # ever fell for, which left every other init running yesterday's schedule.
        command = pkgs.writeShellScript "cron" ''
          # restart trigger: ${cfg.crontabFile}
          exec ${lib.getExe cfg.package} -n ${lib.escapeShellArgs cfg.extraArgs}
        '';
        readiness = "fork";
      };
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/cron";
        mode = "0710";
      }
      {
        type = "directory";
        path = "/var/spool";
        mode = "0755";
      }
      {
        type = "directory";
        path = "/var/spool/cron";
        mode = "0755";
      }

      # ensure this directory exists - cronie complains if it doesn't
      {
        type = "directory";
        path = "/etc/cron.d";
      }
    ];
  };
}
