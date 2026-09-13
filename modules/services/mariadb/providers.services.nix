# how services.mariadb runs, as providers.services units
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
  cfg = config.services.mariadb;
  mysqldOptions = "--user=${cfg.user} --datadir=${cfg.dataDir} --basedir=${cfg.package}";

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.mariadb-init = {
      inherit (cfg) user group;

      description = "mariadb database init";

      # before the tier which completes `basic`, so the database it creates is there for the
      # daemon which serves it
      requires = [ "sysinit" ];

      type.oneshot.command = pkgs.writeShellApplication {
        name = "mariadb-init.sh";
        runtimeInputs = [
          config.programs.coreutils.package
          pkgs.nettools
          pkgs.gnused
        ];
        text = ''
          if ! test -e '${cfg.dataDir}/mysql'; then
            ${cfg.package}/bin/mysql_install_db --defaults-file=/etc/my.cnf ${mysqldOptions}
            touch '${cfg.dataDir}/mysql_init'
          fi
        '';
      };
    };

    providers.services.units.mariadb = {
      inherit (cfg) user group;

      description = "mariadb database service";

      # the logger is behind the tier which completes `basic`; the init is not, so it is named
      requires = [
        "basic"
        "mariadb-init"
      ];

      # a database flushing its buffer pool on the way out is the case this option exists for
      stopTimeout = 120;

      type.service = {
        command = "${cfg.package}/bin/mysqld --defaults-file=/etc/my.cnf ${mysqldOptions}";

        # mysqld speaks sd_notify, which only finit can observe here; elsewhere it is taken as
        # ready once spawned
        readiness = [
          "notify"
          "fork"
        ];
      };
    };

    providers.services.tmpfiles.rules =
      lib.concatMap
        (
          { path, mode }:
          [
            {
              type = "directory";
              inherit path mode;
              inherit (cfg) user group;
            }
            {
              type = "permissions";
              inherit path mode;
              inherit (cfg) user group;
              recursive = true;
            }
          ]
        )
        [
          {
            path = cfg.dataDir;
            mode = "0700";
          }
          {
            path = "/run/mysqld";
            mode = "0755";
          }
        ];
  };
}
