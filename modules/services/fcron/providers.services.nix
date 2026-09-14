# how services.fcron runs, as providers.services units
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
  cfg = config.services.fcron;
  systab = pkgs.writeText "systab" (lib.concatStringsSep "\n" cfg.systab);

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.fcrontab = {
      description = "reload fcrontab";

      # the setuid wrappers are a contract unit, so this is an ordinary edge now rather than a
      # condition naming finit's own task. syslogd is in the head tier and needs no naming.
      requires = [
        "basic"
        "suid-sgid-wrappers"
      ];

      # fcrontab runs fcron's own helpers by name
      path = [ cfg.package ];

      # still a script, for the redirection: a command is exec'd, not run through a shell
      # https://github.com/NixOS/nixpkgs/issues/25072
      type.oneshot.command = pkgs.writeShellScript "fcrontab-reload" ''
        exec ${cfg.package}/bin/fcrontab -u systab - < ${systab}
      '';
    };

    providers.services.units.fcron = {
      description = "fcron daemon";

      # the systab has to be loaded before the daemon reads it. `task/fcrontab/success` named
      # finit's own task; it is a contract unit now, so this is an ordinary edge.
      requires = [
        "basic"
        "fcrontab"
      ];

      # `--foreground`, so the process running is all any backend can observe
      type.service.command = "${cfg.package}/bin/fcron --foreground " + lib.escapeShellArgs cfg.extraArgs;
    };

    providers.services.tmpfiles.rules = lib.optional (cfg.settings.fcrontabs == "/var/spool/fcron") {
      path = cfg.settings.fcrontabs;
      type.directory = {
        mode = "0770";
        user = "fcron";
        group = "fcron";
      };
    };
  };
}
