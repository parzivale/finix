# how services.zerotierone runs, as providers.services units
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
  cfg = config.services.zerotierone;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.zerotierone = {
      description = "zerotier one";

      # syslogd is in the head tier and needs no naming; `net/route/default` was a finit
      # netlink condition, and `network-online` is the portable unit which means the same
      # `multi-user` rather than `basic`, because `network-online` moved there: it used to run
      # a tier ahead of the daemons which bring a link up, which meant it could not see them.
      # Naming it from `basic` now would be a cycle - the level waits for this unit, and this
      # unit waits for a later level - so anything wanting a route waits in the same tier the
      # route appears in.
      requires = [
        "multi-user"
        "network-online"
      ];

      type.service.command = "${cfg.package}/bin/zerotier-one ${cfg.stateDir}";
    };

    providers.services.tmpfiles.rules = lib.optionals (cfg.stateDir == "/var/lib/zerotier-one") [
      {
        type = "directory";
        path = cfg.stateDir;
      }
    ];
  };
}
