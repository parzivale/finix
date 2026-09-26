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

      # Generated beside the path and then written into it, rather than generated at it.
      #
      # Two things make the obvious version fail. The guard is `-s`, false for an empty file,
      # while ssh-keygen's own check is for the path existing at all - so a zero-byte key file
      # falls between them, and ssh-keygen asks
      #
      #   /etc/ssh/ssh_host_ed25519_key already exists.
      #   Overwrite (y/n)?
      #
      # on a stdin nothing is attached to, reads EOF, and exits 1. Silently, as far as the
      # console is concerned: the task is simply `done (status=1)`, its readiness companion waits
      # for a success which will not come, and `sysinit` never completes. The machine stops with
      # the whole trunk behind it and nothing saying why.
      #
      # And clearing the path first does not fix it, because the path is not always the machine's
      # to unlink: a machine which preserves its host key across reboots has that file bind
      # mounted from wherever it persists them, so `rm` gets EBUSY. Which is exactly the machine
      # that hits the zero-byte case, on the first boot, before there is anything to restore.
      #
      # Writing through the path works either way - a bind mount is a file, and `>` truncates
      # and fills whatever is on the other side of it.
      type.oneshot.command = pkgs.writeShellScript "ssh-keygen.sh" ''
        set -eu

        if [ -s "${cfg.hostKeyPath}" ]; then
          exit 0
        fi

        # Before anything is written, not fixed up afterwards. `>` creates a file under this
        # process's umask, and a private key that is 0644 for even a moment is 0644 - the
        # window is not the whole of the problem either, because `set -e` on any later line
        # leaves it that way for good. ssh-keygen writing to its own path got this right by
        # itself; writing through someone else's path means saying so.
        umask 0077

        tmp="$(${lib.getExe' pkgs.coreutils "mktemp"} -d)"
        trap '${lib.getExe' pkgs.coreutils "rm"} -rf "$tmp"' EXIT

        ${cfg.package}/bin/ssh-keygen -q -t ed25519 -f "$tmp/key" -N ""

        # Each mode set against the file it belongs to, immediately. An existing path keeps
        # whatever mode it had - `>` does not change one - and on a machine which preserves its
        # host key that path exists before this runs, so neither of these is redundant.
        ${lib.getExe' pkgs.coreutils "cat"} "$tmp/key" > "${cfg.hostKeyPath}"
        ${lib.getExe' pkgs.coreutils "chmod"} 0600 "${cfg.hostKeyPath}"

        ${lib.getExe' pkgs.coreutils "cat"} "$tmp/key.pub" > "${cfg.hostKeyPath}.pub"
        ${lib.getExe' pkgs.coreutils "chmod"} 0644 "${cfg.hostKeyPath}.pub"
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
