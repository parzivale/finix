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

      type.service = {
        # the daemon reads /etc/nix/nix.conf, but the unit names the file that was generated
        # from, so a changed configuration is a changed unit and the daemon is restarted with
        # it. The "standard nixos trick" this replaces was appended to finit.d/nix-daemon.conf
        # - a trick only finit ever fell for.
        command = pkgs.writeShellScript "nix-daemon" ''
          # restart trigger: ${cfg.configFile}
          exec ${cfg.package}/bin/nix-daemon --daemon
        '';
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

  };
}
