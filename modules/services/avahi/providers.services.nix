# how services.avahi runs, as providers.services units
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
  cfg = config.services.avahi;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.avahi-daemon = {
      description = "avahi daemon service";

      # nothing about syslogd or the bus: both are in the head tier, with the bus's socket gate
      # beside it, so anything here is after them
      requires = [ "basic" ];

      # the daemon reads /etc/avahi/avahi-daemon.conf from a fixed path and names it
      # nowhere, so without this a changed configuration leaves it running with what it
      # read at boot. It has a `reload` below, so the switch re-reads rather than restarts.
      restartTriggers = [ cfg.configFile ];

      type.service = {
        command = lib.escapeShellArgs ([ (lib.getExe' cfg.package "avahi-daemon") ] ++ cfg.extraArgs);

        # and now it is a reload rather than a restart, which keeps the published records up
        reload = "${lib.getExe' cfg.package "avahi-daemon"} -r";
      };
    };
  };
}
