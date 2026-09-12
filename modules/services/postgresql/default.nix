{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.postgresql // {
    user = "postgres";
    group = "postgres";
  };

  format = pkgs.formats.keyValue {
    mkKeyValue = lib.generators.mkKeyValueDefault {
      mkValueString =
        v: if lib.isString v || lib.isPath v then "'${v}'" else lib.generators.mkValueStringDefault { } v;
    } " = ";
  };
in
{
  options.services.postgresql = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [postgresql](${pkgs.postgresql.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        The package to use for `postgresql`.
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to `postgresql`. See {manpage}`postgres(1)`
        for additional details.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/postgresql/${cfg.package.psqlSchema}";
      defaultText = lib.literalExpression ''"/var/lib/postgresql/''${config.services.postgresql.package.psqlSchema}"'';
      description = ''
        The directory used to store all `postgresql` data.

        ::: {.note}
        If left as the default value this directory will automatically be created on
        system activation, otherwise you are responsible for ensuring the directory exists
        with appropriate ownership and permissions before the `postgresql` service starts.
        :::
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `postgresql` configuration. See [upstream documentation](https://www.postgresql.org/docs/current/config-setting.html#CONFIG-SETTING-CONFIGURATION-FILE)
        for additional details.
      '';
    };

    authentication = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        `postgresql` client authentication configuration. See [upstream documentation](https://www.postgresql.org/docs/current/auth-pg-hba-conf.html)
        for additional details.
      '';
    };

    identity = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        `postgresql` user name maps configuration. See [upstream documentation](https://www.postgresql.org/docs/current/auth-username-maps.html)
        for additional details.
      '';
    };

    initdb = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create a new `postgresql` database cluster.
        '';
      };

      extraArgs = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          Additional arguments to pass to `initdb`. See {manpage}`initdb(1)`
          for additional details.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql.initdb.extraArgs = [ "--allow-group-access" ];
    services.postgresql.extraArgs = [
      "--config-file=/etc/postgresql/${cfg.package.psqlSchema}/postgresql.conf"
    ];
    services.postgresql.settings = {
      data_directory = lib.mkForce cfg.dataDir;
      hba_file = "/etc/postgresql/${cfg.package.psqlSchema}/pg_hba.conf";
      ident_file = "/etc/postgresql/${cfg.package.psqlSchema}/pg_ident.conf";
      log_destination = "syslog";

      # drop redundant timestamp and pid
      log_line_prefix = lib.mkDefault "";
    };
    services.postgresql.authentication = lib.mkBefore ''
      # TYPE  DATABASE        USER            ADDRESS                 METHOD
      local   all             postgres        peer                    map=postgres
    '';
    services.postgresql.identity = lib.mkBefore ''
      # MAPNAME       SYSTEM-USERNAME      DATABASE-USERNAME
      postgres        ${cfg.user}             postgres
    '';

    environment.systemPackages = [ cfg.package ];

    environment.etc."postgresql/${cfg.package.psqlSchema}/pg_ident.conf".text = cfg.identity;
    environment.etc."postgresql/${cfg.package.psqlSchema}/pg_hba.conf".text = cfg.authentication;
    environment.etc."postgresql/${cfg.package.psqlSchema}/postgresql.conf".source =
      format.generate "postgresql.conf" cfg.settings;

    # `pre` was finit running this as part of starting the service; the contract has no
    # such step, and a database which has to be created before it can be served is a unit of
    # its own anyway - it runs as the postgres user, exactly as the `pre` did.
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

    users.users.${cfg.user} = {
      name = cfg.user;
      group = cfg.group;
      home = cfg.dataDir;
      uid = config.ids.uids.postgres;
    };

    users.groups.${cfg.group} = {
      gid = config.ids.gids.postgres;
    };
  };
}
