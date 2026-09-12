# how services.sonarr runs, as providers.services units
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
  cfg = config.services.sonarr;
  toEnvVars =
    settings:
    lib.listToAttrs (
      lib.collect (x: lib.isString x.name or false && lib.isString x.value or false) (
        lib.mapAttrsRecursive (
          path: value:
          lib.optionalAttrs (value != null) {
            name = lib.toUpper "SONARR__${lib.concatStringsSep "__" path}";
            value = toString (if lib.isBool value then lib.boolToString value else value);
          }
        ) settings
      )
    );

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sonarr = {
      inherit (cfg) user group;

      description = "sonarr";

      # syslogd is in the head tier; `net/route/default` was a finit netlink condition, and
      # `network-online` is the portable unit which means the same
      requires = [
        "basic"
        "network-online"
      ];

      type.service.command = "${lib.getExe cfg.package} -nobrowser -data=${cfg.dataDir}";

      environment = toEnvVars cfg.settings;
    };
  };
}
