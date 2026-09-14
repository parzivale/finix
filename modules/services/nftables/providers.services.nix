# how services.nftables runs, as providers.services units
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
  cfg = config.services.nftables;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.nftables = {
      description = "load the firewall ruleset";

      # `sysinit`, so the ruleset is in place before the basic tier - a machine should not be
      # reachable before its firewall is. syslogd is in the head tier and needs no naming.
      requires = [ "sysinit" ];

      type.oneshot.command = cfg.startScript;
    };

    providers.services.units.nftables-flush = {
      description = "unload the firewall ruleset";
      requires = [ "stopped" ];

      type.oneshot.command = cfg.stopScript;
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/lib/nftables";
        type.directory.mode = "0700";
      }

      # created empty if it is not there, because the ruleset `include`s it on the way in and
      # nft fails on a missing include. Never truncated here - what it holds is the deletions
      # belonging to the ruleset currently loaded, which is state the next generation needs.
      {
        path = cfg.stateFile;
        type.file.mode = "0600";
      }
    ];
  };
}
