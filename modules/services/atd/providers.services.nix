# how services.atd runs, as providers.services units
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
  cfg = config.services.atd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.atd = {
      description = "deferred execution scheduler";
      requires = [ "basic" ];

      type.service = {
        # `-f` is foreground, so ready-on-fork is the only honest answer. `notify = "pid"`
        # asked finit to manage a pid file on the daemon's behalf, which says nothing about
        # readiness and would be read by dinit as a daemon which forks and exits - which a
        # foreground process never does.
        command = "${pkgs.at}/bin/atd -f " + lib.escapeShellArgs cfg.extraArgs;
        readiness = "fork";
      };
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/spool/atjobs";
        mode = "1770";
        user = "atd";
        group = "atd";
      }
      {
        type = "file";
        path = "/var/spool/atjobs/.SEQ";
        mode = "0600";
        user = "atd";
        group = "atd";
      }
      {
        type = "directory";
        path = "/var/spool/atspool";
        mode = "1770";
        user = "atd";
        group = "atd";
      }
    ];
  };
}
