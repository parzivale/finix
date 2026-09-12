{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.vnstat;

  format = pkgs.formats.keyValue {
    mkKeyValue = lib.generators.mkKeyValueDefault { } " ";
  };

  configFile = format.generate "vnstat.conf" cfg.settings;
in
{
  options.services.vnstat = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [vnstat](${pkgs.vnstat.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.vnstat;
      defaultText = lib.literalExpression "pkgs.vnstat";
      description = ''
        The package to use for `vnstat`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "vnstatd";
      description = ''
        User account under which `vnstat` runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `vnstat` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "vnstatd";
      description = ''
        Group account under which `vnstat` runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `vnstat` service starts.
        :::
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to `vnstat`. See {manpage}`vnstatd(8)`
        for additional details.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;

        options = {
          DatabaseDir = lib.mkOption {
            type = with lib.types; either str path;
            default = "/var/lib/vnstat";
            description = ''
              Specifies the directory where interface databases are to be stored.
            '';
          };

          UseLogging = lib.mkOption {
            type =
              with lib.types;
              either int (enum [
                "disabled"
                "logfile"
                "syslog"
              ]);
            default = "syslog";
            apply =
              value:
              if value == "disabled" then
                0
              else if value == "logfile" then
                1
              else if value == "syslog" then
                2
              else
                value;
            description = ''
              Enable or disable logging.
            '';
          };
        };
      };
      default = { };
      description = ''
        `vnstat` configuration. See {manpage}`vnstat.conf(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.vnstat.extraArgs = [
      "--nodaemon"
      "--config"
      "/etc/vnstat.conf"
    ]
    ++ lib.optionals cfg.debug [ "--debug" ];

    environment.systemPackages = [ cfg.package ];
    environment.etc."vnstat.conf".source = configFile;

    providers.services.tmpfiles.rules = lib.optionals (cfg.settings.DatabaseDir == "/var/lib/vnstat") [
      {
        type = "directory";
        path = cfg.settings.DatabaseDir;
        mode = "0750";
        inherit (cfg) user group;
      }
    ];

    providers.services.units.vnstat = {
      inherit (cfg) user group;

      description = "vnStat network traffic monitor";
      requires = [ "basic" ];

      type.service = {
        # vnstatd reads /etc/vnstat.conf, but the unit names the file that was generated from,
        # so a changed configuration is a changed unit. The `# reload trigger` this replaces
        # was appended to finit.d/vnstat.conf, and so reached finit alone.
        command = pkgs.writeShellScript "vnstatd" ''
          # reload trigger: ${configFile}
          exec ${pkgs.vnstat}/bin/vnstatd ${lib.escapeShellArgs cfg.extraArgs}
        '';

        # and it is a reload now rather than a restart: vnstatd rereads its configuration on
        # SIGHUP, and restarting it drops whatever it has not yet written to the database
        reload = "${lib.getExe' pkgs.procps "pkill"} -HUP -x vnstatd";
      };
    };

    users.users = lib.optionalAttrs (cfg.user == "vnstatd") {
      vnstatd = {
        inherit (cfg) group;

        isSystemUser = true;
        description = "vnstat daemon user";
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "vnstatd") {
      vnstatd = { };
    };
  };
}
