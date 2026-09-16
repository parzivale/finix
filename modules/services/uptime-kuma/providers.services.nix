# how services.uptime-kuma runs, as providers.services units
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
  cfg = config.services.uptime-kuma;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.uptime-kuma = {
      inherit (cfg) user group;

      description = "uptime kuma";

      # `multi-user` rather than `basic`, because `network-online` moved there: it used to run
      # a tier ahead of the daemons which bring a link up, which meant it could not see them.
      # Naming it from `basic` now would be a cycle - the level waits for this unit, and this
      # unit waits for a later level - so anything wanting a route waits in the same tier the
      # route appears in.
      requires = [
        "multi-user"
        "network-online"
      ];

      # `kill = 10` becomes the contract's stopTimeout, which every implementation bounds
      # except runit - and says so.
      stopTimeout = lib.mkDefault 10;

      # uptime-kuma runs ping by name for its monitors
      path = [ pkgs.unixtools.ping ];

      type.service.command = lib.getExe cfg.package;

      # the settings are typed as what they are - PORT is a `types.port`, which is a number -
      # and an environment is strings. Converted here, at the boundary where one becomes the
      # other, rather than by weakening the option to `str` and losing the check.
      environment = lib.mapAttrs (
        _: v: if lib.isBool v then lib.boolToString v else toString v
      ) cfg.settings;
    };

    providers.services.tmpfiles.rules = lib.optional (cfg.settings.DATA_DIR == "/var/lib/uptime-kuma") {
      path = cfg.settings.DATA_DIR;
      type.directory = {
        mode = "0750";
        inherit (cfg) user group;
      };
    };
  };
}
