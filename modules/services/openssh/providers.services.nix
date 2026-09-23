# how services.openssh runs, as providers.services units
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
  cfg = config.services.openssh;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.ssh-keygen = {
      description = "generate ssh host keys";

      # before anything can serve with them, and before the tier which completes `basic`
      requires = [ "sysinit" ];

      type.oneshot.command = pkgs.writeShellScript "ssh-keygen.sh" ''
        if ! [ -s "${cfg.hostKeyPath}" ]; then
          ${cfg.package}/bin/ssh-keygen -t ed25519 -f "${cfg.hostKeyPath}" -N ""
        fi
      '';
    };

    providers.services.units.sshd = {
      description = "openssh daemon";

      # `basic`, where the rest of the network daemons are. `net/lo/up` and
      # `service/syslogd/ready` are both behind it - loopback and the logger come up in the
      # tier which completes `basic` - so only the keys still need naming, and they are named
      # because a daemon serving before they exist offers a host identity it then changes.
      requires = [
        "basic"
        "ssh-keygen"
      ];

      type.service = {
        command = "${cfg.package}/bin/sshd -D -f /etc/ssh/sshd_config";

        # `notify:pid` was finit waiting for the pid file. The portable form of that is
        # `waitFor.path` and not `waitFor.pidfile`: the pidfile kind also says the daemon
        # forks into the background to write it, and `-D` is sshd being told not to. An
        # implementation waiting for that fork would fail the unit on its start timeout.
        readiness.waitFor.path.path = "/run/sshd.pid";

        # sshd rereads its configuration on SIGHUP, and re-execs itself doing it, so a switch
        # which only changed sshd_config need not drop the listening socket. By the pid file
        # rather than by name: a session is an `sshd` process too, and a HUP to one of those
        # ends somebody's login.
        reload = "${lib.getExe' pkgs.coreutils "kill"} -HUP \"$(${lib.getExe' pkgs.coreutils "cat"} /run/sshd.pid)\"";
      };
    };

    providers.services.tmpfiles.rules = [
      {
        path = builtins.dirOf cfg.hostKeyPath;
        type.directory.mode = "0755";
      }
    ];
  };
}
