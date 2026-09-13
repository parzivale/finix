# how services.postgresql runs, as providers.services units
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
  cfg = config.services.postgresql;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.postgresql-initdb = lib.mkIf cfg.initdb.enable {
      description = "create the postgresql cluster";

      inherit (cfg) user group;
      requires = [ "sysinit" ];

      type.oneshot.command = pkgs.writeShellScript "postgresql-initdb.sh" ''
        if [ ! -f "${cfg.dataDir}/PG_VERSION" ]; then
          ${lib.getExe' cfg.package "initdb"} ${lib.escapeShellArgs cfg.initdb.extraArgs} ${cfg.dataDir}
        fi
      '';
    };

    providers.services.units.postgresql = {
      description = "postgresql database service";

      inherit (cfg) user group;

      # the logger and loopback are both behind the tier which completes `basic`
      requires = [
        "basic"
      ]
      ++ lib.optional cfg.initdb.enable "postgresql-initdb";

      # `kill = 120` was finit's; a database is the case the option was written for. A
      # checkpoint on shutdown can take minutes on a large cluster, and being killed part way
      # through one is how a cluster comes back needing recovery.
      stopTimeout = 120;

      type.service = {
        command = "${lib.getExe' cfg.package "postgres"} " + lib.escapeShellArgs cfg.extraArgs;

        # postgres rereads postgresql.conf, pg_hba.conf and pg_ident.conf on SIGHUP, which is
        # what the commented-out "reload trigger" in the generated finit stanza was reaching
        # for. Signalled directly rather than through `pg_ctl reload`, which refuses to run as
        # root, and a reload command is run by whatever is doing the switch.
        reload = "${lib.getExe' pkgs.coreutils "kill"} -HUP \"$(${lib.getExe' pkgs.coreutils "head"} -n1 ${cfg.dataDir}/postmaster.pid)\"";
      };

      path = [ cfg.package ];
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/run/postgresql";
        inherit (cfg) user group;
      }
    ]
    ++ lib.optionals (cfg.dataDir == "/var/lib/postgresql/${cfg.package.psqlSchema}") (
      map
        (path: {
          type = "directory";
          inherit path;
          mode = "0750";
          inherit (cfg) user group;
        })
        [
          "/var/lib/postgresql"
          "/var/lib/postgresql/${cfg.package.psqlSchema}"
        ]
    );
  };
}
