# how services.elogind runs, as providers.services units
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
  cfg = config.services.elogind;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.elogind = {
      description = "login manager";

      # `sysinit`, beside seatd and the bus: seat and session management is infrastructure that
      # the tier above is entitled to assume, in the same way it assumes logging and device
      # nodes. Anything in a later tier - a login prompt, polkit - is then after it by the
      # trunk rather than by naming it, and naming it would have meant an optional edge, which
      # hides a requirement rather than stating it.
      #
      # Nothing about the bus either: it and its socket gate are in the head tier, and this is
      # in the one after, so it is already behind both.
      requires = [ "sysinit" ];

      # elogind reads these from fixed paths under /etc and names them nowhere, so without
      # this a changed configuration leaves the daemon running with the old one. Declared
      # rather than smuggled into the command as a comment, which is what this used to be.
      restartTriggers = [
        cfg.loginConf
        cfg.sleepConf
      ];

      type.service = {
        command = "${cfg.package}/libexec/elogind";

        # elogind speaks sd_notify, which only finit can observe here; everywhere else it is
        # taken as ready once spawned, the same bargain sessiond and mdevd make
        readiness = [
          "notify"
          "fork"
        ];
      };

      environment = {
        SYSTEMD_LOG_TARGET = "syslog";
      }
      // lib.optionalAttrs cfg.debug {
        SYSTEMD_LOG_LEVEL = "debug";
      };
    };
  };
}
