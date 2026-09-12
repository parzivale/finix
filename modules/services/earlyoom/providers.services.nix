# how services.earlyoom runs, as providers.services units
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
  cfg = config.services.earlyoom;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.earlyoom = {
      description = "early oom daemon";
      requires = [ "basic" ];

      # with `-n` earlyoom sends desktop notifications through dbus-send
      path = lib.optional (lib.elem "-n" cfg.extraArgs) pkgs.dbus;

      # `cgroup.settings` is gone with the stanza - finit's own resource limits, which the
      # contract does not model and no other implementation would honour.
      type.service.command = "${cfg.package}/bin/earlyoom --syslog " + lib.escapeShellArgs cfg.extraArgs;
    };
  };
}
