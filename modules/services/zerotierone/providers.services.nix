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
      requires = [
        "basic"
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
