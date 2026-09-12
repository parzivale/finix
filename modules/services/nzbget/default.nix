{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.nzbget;
  logDir = "/var/log/nzbget";
  configFile = "${cfg.stateDir}/nzbget.conf";
in
{
  imports = [ ./providers.services.nix ];

  options.services.nzbget = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [nzbget](${pkgs.nzbget.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nzbget;
      defaultText = lib.literalExpression "pkgs.nzbget";
      description = ''
        The package to use for `nzbget`.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nzbget";
      description = ''
        User account under which `nzbget` runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `nzbget` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nzbget";
      description = ''
        Group account under which `nzbget` runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `nzbget` service starts.
        :::
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nzbget";
      description = ''
        The directory used to store all `nzbget` data.

        ::: {.note}
        If left as the default value this directory will automatically be created on
        system activation, otherwise you are responsible for ensuring the directory exists
        with appropriate ownership and permissions before the `nzbget` service starts.
        :::
      '';
    };

    settings = lib.mkOption {
      type =
        with lib.types;
        attrsOf (oneOf [
          bool
          int
          str
        ]);
      default = { };
      description = ''
        `nzbget` configuration. See [upstream documentation](https://nzbget.com/documentation/command-line-reference)
        for additional details.
      '';
      example = {
        MainDir = "/data";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.nzbget.settings = {
      MainDir = cfg.stateDir;

      # allows nzbget to run as a "simple" service
      OutputMode = "loggable";

      # use builtin nzbget logging
      LogFile = "${logDir}/nzbget.log";
      WriteLog = "rotate";
      ErrorTarget = "log";
      WarningTarget = "log";
      InfoTarget = "log";
      DetailTarget = "log";

      # required paths
      ConfigTemplate = "${cfg.package}/share/nzbget/nzbget.conf";
      WebDir = "${cfg.package}/share/nzbget/webui";
      SevenZipCmd = lib.getExe pkgs.p7zip;
      UnrarCmd = lib.getExe pkgs.unrar;

      # nixos handles package updates
      UpdateCheck = "none";
    };

    users.users = lib.mkIf (cfg.user == "nzbget") {
      nzbget = {
        home = cfg.stateDir;
        group = cfg.group;
        uid = config.ids.uids.nzbget;
      };
    };

    users.groups = lib.mkIf (cfg.group == "nzbget") {
      nzbget = {
        gid = config.ids.gids.nzbget;
      };
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = logDir;
        mode = "0750";
        inherit (cfg) user group;
      }
    ]
    ++ lib.optional (cfg.stateDir == "/var/lib/nzbget") {
      type = "directory";
      path = cfg.stateDir;
      mode = "0750";
      inherit (cfg) user group;
    };
  };
}
