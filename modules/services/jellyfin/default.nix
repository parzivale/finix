{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.jellyfin;
in
{
  options.services.jellyfin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [jellyfin](${pkgs.jellyfin.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.jellyfin;
      defaultText = lib.literalExpression "pkgs.jellyfin";
      description = ''
        The package to use for `jellyfin`.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/jellyfin";
      description = ''
        The directory used to store all `jellyfin` data.

        ::: {.note}
        If left as the default value this directory will automatically be created on
        system activation, otherwise you are responsible for ensuring the directory exists
        with appropriate ownership and permissions before the `jellyfin` service starts.
        :::
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      description = ''
        User account under which `jellyfin` runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `jellyfin` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      description = ''
        Group account under which `jellyfin` runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `jellyfin` service starts.
        :::
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    providers.services.units.jellyfin = {
      inherit (cfg) user group;

      description = "jellyfin media server";
      requires = [ "basic" ];

      type.service.command = "${lib.getExe cfg.package} --datadir ${cfg.dataDir} --configdir ${cfg.dataDir}/config --cachedir /var/cache/jellyfin --logdir /var/log/jellyfin";
    };

    providers.services.tmpfiles.rules =
      let
        owned = mode: path: {
          type = "directory";
          inherit path mode;
          inherit (cfg) user group;
        };
      in
      [
        (owned "0700" "/var/cache/jellyfin")
        (owned "0750" "/var/log/jellyfin")
      ]
      ++ lib.optionals (cfg.dataDir == "/var/lib/jellyfin") [
        (owned "0700" cfg.dataDir)
        (owned "0700" "${cfg.dataDir}/config")
      ];

    users.users = lib.optionalAttrs (cfg.user == "jellyfin") {
      jellyfin = {
        group = "jellyfin";
        isSystemUser = true;
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "jellyfin") {
      jellyfin = { };
    };
  };
}
