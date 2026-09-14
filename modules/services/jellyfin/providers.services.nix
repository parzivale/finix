# how services.jellyfin runs, as providers.services units
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
  cfg = config.services.jellyfin;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.jellyfin = {
      inherit (cfg) user group;

      description = "jellyfin media server";
      requires = [ "basic" ];

      type.service.command = "${lib.getExe cfg.package} --datadir ${cfg.dataDir} --configdir ${cfg.dataDir}/config --cachedir /var/cache/jellyfin --logdir /var/log/jellyfin";
    };

    users.users = lib.optionalAttrs (cfg.user == "jellyfin") {
      jellyfin = {
        group = "jellyfin";
        isSystemUser = true;
      };
    };

    providers.services.tmpfiles.rules =
      let
        owned = mode: path: {
          inherit path;
          type.directory = {
            inherit mode;
            inherit (cfg) user group;
          };
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
  };
}
