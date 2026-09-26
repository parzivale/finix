# how services.nix-daemon runs, as providers.services units
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
  cfg = config.services.nix-daemon;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.nix-daemon = {
      description = "nix daemon";

      # read from a fixed path and named nowhere else, so a changed configuration
      # would otherwise leave the daemon running with the old one
      reloadTriggers = [ cfg.configFile ];

      type.service = {
        # the daemon reads /etc/nix/nix.conf, but the unit names the file that was generated
        # from, so a changed configuration is a changed unit and the daemon is restarted with
        # it. The "standard nixos trick" this replaces was appended to finit.d/nix-daemon.conf
        # - a trick only finit ever fell for.
        command = "${cfg.package}/bin/nix-daemon --daemon";

        # Ready when it answers, not when it has forked.
        #
        # `fork` meant the daemon was called ready the moment it existed, which is well before it
        # accepts anything - and a client starting in that window does not wait, it fails:
        #
        #   error: cannot connect to socket at '/nix/var/nix/daemon-socket/socket':
        #   Connection refused
        #
        # which is what home-manager activation hit, and because a display manager was ordered
        # behind that activation the whole session was lost with it. Intermittently, since it is a
        # race the daemon usually wins.
        #
        # `waitFor.socket` connects rather than testing that a path exists, which is the
        # difference that matters here: the socket file appears at bind(), before anything is
        # listening on it, so `[ -S ... ]` is true during exactly the window that breaks clients.
        readiness = [ { waitFor.socket.path = "/nix/var/nix/daemon-socket/socket"; } ];
      };

      environment.CURL_CA_BUNDLE = config.security.pki.caBundle;

      # `basic` puts it in the multi-user tier: nothing earlier needs to build anything, and
      # gating the basic tier on the daemon would hold the trunk for something no other
      # service waits on. syslogd is in the head tier, so this is already after it.
      requires = [ "basic" ];
    };

    # Kept as a name for consumers to require, now that `nix-daemon` itself means "answering":
    # its readiness is the connect above, so requiring either is the same gate. It was this unit
    # doing the waiting before, with `[ -S ... ]`, which is the test that let clients through
    # early - see the note on readiness.
    providers.services.units.nix-daemon-socket = {
      description = "the nix daemon is accepting connections";
      requires = [ "nix-daemon" ];

      type.oneshot.command = lib.getExe' pkgs.coreutils "true";
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/nix/var";
        type.directory.mode = "0755";
      }
      {
        path = "/nix/var/nix/daemon-socket";
        type.directory.mode = "0755";
      }
      {
        type = "directory";
        path = "/nix/var/nix/gcroots";
      }
      {
        path = "/nix/var/nix/gcroots/tmp";
        type.remove.recursive = true;
      }
      {
        path = "/nix/var/nix/temproots";
        type.remove.recursive = true;
      }

      # so the running and booted systems are not garbage-collected out from under the machine
      {
        path = "/nix/var/nix/gcroots/booted-system";
        type.symlink.argument = "/run/booted-system";
      }
      {
        path = "/nix/var/nix/gcroots/current-system";
        type.symlink.argument = "/run/current-system";
      }
    ];
  };
}
