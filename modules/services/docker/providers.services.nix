# how services.docker runs, as providers.services units
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
  cfg = config.services.docker;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.docker = {
      description = "docker daemon";

      # `hook/net/up` was a finit hook condition, which nothing else has; `network-online` is
      # the portable unit meaning the same. syslogd is in the head tier and needs no naming.
      # `multi-user` rather than `basic`, because `network-online` moved there: it used to run
      # a tier ahead of the daemons which bring a link up, which meant it could not see them.
      # Naming it from `basic` now would be a cycle - the level waits for this unit, and this
      # unit waits for a later level - so anything wanting a route waits in the same tier the
      # route appears in.
      requires = [
        "multi-user"
        "network-online"
      ];

      # dockerd runs modprobe and the configured extra packages by name
      path = [ pkgs.kmod ] ++ cfg.extraPackages;

      type.service = {
        command = "${cfg.package}/bin/dockerd " + lib.escapeShellArgs cfg.extraArgs;

        # `reload` was `kill -s HUP $MAINPID` - finit's own substitution for the service's pid,
        # which nothing else has. dockerd reloads on SIGHUP, so the same thing said without
        # asking the supervisor for the pid.
        reload = "${pkgs.procps}/bin/pkill -HUP -x dockerd";

        # dockerd speaks sd_notify; where the implementation cannot observe it, the daemon is
        # taken as ready once spawned
        readiness = [
          "notify"
          "fork"
        ];
      };
    };
  };
}
