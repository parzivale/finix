# how services.rsyslog runs, as providers.services units
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
  cfg = config.services.rsyslog;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.syslogd = {
      description = "system logging daemon";

      type.service = {
        command = "${pkgs.rsyslog-light}/bin/rsyslogd -n -d -f ${cfg.configFile}";

        # `-n` is foreground, so ready-on-fork is the only honest answer here - the same
        # bargain sysklogd makes, and for the same reason
        readiness = "fork";
      };

      # the head of the trunk, so logging is up before `sysinit` and everything in a later
      # tier can log without naming it. The device manager comes first where there is one:
      # /dev/log has to exist before anything can log to it. This is the same shape as
      # sysklogd's unit, deliberately - the two are alternatives under one name, and a
      # machine enabling both is one definition of `syslogd` colliding with another, which
      # is exactly the error it should be.
      requires = [
        (lib.head config.providers.services.trunk.levels)
      ]
      ++ lib.optional config.services.udev.enable "udev-settle"
      ++ lib.optional config.services.mdevd.enable "coldplug";
    };
  };
}
