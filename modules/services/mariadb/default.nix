{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.mariadb;

  format = pkgs.formats.ini { listsAsDuplicateKeys = true; };
  configFile = format.generate "my.cnf" cfg.settings;

  mysqldOptions = "--user=${cfg.user} --datadir=${cfg.dataDir} --basedir=${cfg.package}";
in
{
  imports = [ ./providers.services.nix ];

  options.services.mariadb = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [mariadb](${pkgs.mariadb.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mariadb;
      description = ''
        The package to use for `mariadb`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "mariadb";
      description = ''
        User account under which `mariadb` runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `mariadb` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "mariadb";
      description = ''
        Group account under which `mariadb` runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `mariadb` service starts.
        :::
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mariadb";
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        MySQL configuration. Refer to
        <https://dev.mysql.com/doc/refman/5.7/en/server-system-variables.html>,
        <https://dev.mysql.com/doc/refman/8.0/en/server-system-variables.html>,
        and <https://mariadb.com/kb/en/server-system-variables/>
        for details on supported values.

        ::: {.note}
        MySQL configuration options such as `--quick` should be treated as
        boolean options and provided values such as `true`, `false`,
        `1`, or `0`. See the provided example below.
        :::
      '';
      example = lib.literalExpression ''
        {
          mysqld = {
            key_buffer_size = "6G";
            table_cache = 1600;
            log-error = "/var/log/mysql_err.log";
            plugin-load-add = [ "server_audit" "ed25519=auth_ed25519" ];
          };
          mysqldump = {
            quick = true;
            max_allowed_packet = "16M";
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.mariadb.settings.mysqld = {
      datadir = cfg.dataDir;
      port = lib.mkDefault 3306;
    };

    users.users = lib.mkIf (cfg.user == "mariadb") {
      mariadb = {
        inherit (cfg) group;

        isSystemUser = true;
      };
    };

    users.groups = lib.mkIf (cfg.group == "mariadb") {
      mariadb = { };
    };

    environment.systemPackages = [
      cfg.package
    ];

    environment.etc."my.cnf".source = configFile;

    # the `d` rule creates it, the `permissions` rule fixes up what is already inside it -
    # which is what the `Z` lines were for, and is recursive here rather than the FIXME it was

  };
}
