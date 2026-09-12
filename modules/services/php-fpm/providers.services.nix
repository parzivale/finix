# how services.php-fpm runs, as providers.services units
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
  cfg = config.services.php-fpm;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.php-fpm = {
      description = "php fastcgi process manager";

      # the logger is in the tier which completes `basic`, so `service/syslogd/ready` is
      # behind this without being named
      requires = [ "basic" ];

      type.service = {
        command = "${cfg.package}/bin/php-fpm -y ${cfg.configFile}";

        # php-fpm speaks sd_notify, which only finit can observe here; elsewhere it is taken
        # as ready once spawned
        readiness = [
          "notify"
          "fork"
        ];

        # USR2 is a graceful reload of the workers, and it is the master which must receive
        # it. `$MAINPID` was finit's; the portable way to say the same thing is to match the
        # title php-fpm gives its master process, since every worker is an `php-fpm` too.
        reload = "${lib.getExe' pkgs.procps "pkill"} -USR2 -f '^php-fpm: master process'";
      };
    };

  };
}
