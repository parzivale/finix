# the hostname and the wait for a route, as providers.services units
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    providers.services.units.set-hostname = {
      description = "apply the configured hostname";
      type.oneshot.command = "${lib.getExe' pkgs.nettools "hostname"} -F /etc/hostname";

      # early, so that anything logging or announcing itself later says the right name
      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };

    providers.services.units.network-online = {
      description = "wait for a default route";

      # the multi-user tier, which is where the things that make a route are.
      #
      # It was attached to `sysinit`, one tier ahead of dhcpcd and iwd - so it ran before
      # anything had tried to bring a link up, could only pass on a machine which already had a
      # route, and on a wireless one spent its whole five seconds and gave up every boot. That
      # made it two things at once: a wait which could not observe what it was waiting for, and
      # five seconds in front of `basic`, which is in front of `multi-user`, which is what a
      # login prompt and a compositor wait for. A machine with no route took five seconds
      # longer to show anybody anything, for a check that had already failed.
      #
      # Here it starts beside the daemons which configure the network rather than ahead of
      # them, and the only thing behind it is `running` - so a unit which genuinely needs a
      # route still waits, and nothing which merely needs a session does.
      requires = [ "multi-user" ];

      type.oneshot.command = pkgs.writeShellScript "network-online" ''
        for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 50); do
          if [ -s /proc/net/route ] && ${lib.getExe' pkgs.gnugrep "grep"} -qE '^[^	]+	00000000	' /proc/net/route; then
            exit 0
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        echo "network-online: no default route after 5s, continuing" >&2
      '';
    };
  };
}
