# how services.vnstat runs, as providers.services units
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
  cfg = config.services.vnstat;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.vnstat = {
      inherit (cfg) user group;

      description = "vnStat network traffic monitor";
      requires = [ "basic" ];

      type.service = {
        # vnstatd reads /etc/vnstat.conf, but the unit names the file that was generated from,
        # so a changed configuration is a changed unit. The `# reload trigger` this replaces
        # was appended to finit.d/vnstat.conf, and so reached finit alone.
        command = pkgs.writeShellScript "vnstatd" ''
          # reload trigger: ${cfg.configFile}
          exec ${pkgs.vnstat}/bin/vnstatd ${lib.escapeShellArgs cfg.extraArgs}
        '';

        # and it is a reload now rather than a restart: vnstatd rereads its configuration on
        # SIGHUP, and restarting it drops whatever it has not yet written to the database
        reload = "${lib.getExe' pkgs.procps "pkill"} -HUP -x vnstatd";
      };
    };

    providers.services.tmpfiles.rules = lib.optionals (cfg.settings.DatabaseDir == "/var/lib/vnstat") [
      {
        type = "directory";
        path = cfg.settings.DatabaseDir;
        mode = "0750";
        inherit (cfg) user group;
      }
    ];
  };
}
