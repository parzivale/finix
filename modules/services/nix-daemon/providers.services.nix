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
        readiness = "fork";
      };

      environment.CURL_CA_BUNDLE = config.security.pki.caBundle;

      # `basic` puts it in the multi-user tier: nothing earlier needs to build anything, and
      # gating the basic tier on the daemon would hold the trunk for something no other
      # service waits on. syslogd is in the head tier, so this is already after it.
      requires = [ "basic" ];
    };

    providers.services.units.nix-daemon-socket = {
      description = "wait for the nix daemon socket";
      requires = [ "nix-daemon" ];

      type.oneshot.command = pkgs.writeShellScript "nix-daemon-wait" ''
        for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 100); do
          if [ -S /nix/var/nix/daemon-socket/socket ]; then
            exit 0
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        echo "nix-daemon-socket: the daemon never started listening" >&2
        exit 1
      '';
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

      # The profile roots. Every other directory a nix installation needs is above; this was the
      # one missing, and what a machine without it looks like is a user profile operation failing
      # with
      #
      #   error: creating directory "/nix/var/nix/profiles": Permission denied
      #
      # because nothing made it and the user running the operation cannot. `per-user` too, since
      # a per-user profile is created inside it and the same applies.
      #
      # Easy to miss on a machine converted from another distribution, which already has these
      # from whatever installed nix in the first place. A machine finix installed does not.
      {
        path = "/nix/var/nix/profiles";
        type.directory.mode = "0755";
      }
      {
        path = "/nix/var/nix/profiles/per-user";
        type.directory.mode = "0755";
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
