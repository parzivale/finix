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

      type.service = {
        # the daemon reads /etc/avahi/avahi-daemon.conf, but the unit names the file it was
        # generated from, so that a changed configuration is a changed unit. That is what the
        # `# reload trigger` comment appended to finit.d/avahi-daemon.conf was doing, and it
        # was doing it for finit alone - everywhere else a config change left the daemon
        # running with what it read at boot.
        command = pkgs.writeShellScript "avahi-daemon" ''
          # reload trigger: ${cfg.configFile}
          exec ${
            lib.escapeShellArgs (
              [
                (lib.getExe' cfg.package "avahi-daemon")
              ]
              ++ cfg.extraArgs
            )
          }
        '';

        # and now it is a reload rather than a restart, which keeps the published records up
        reload = "${lib.getExe' cfg.package "avahi-daemon"} -r";
      };
    };
  };
}
