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
      requires = [ "sysinit" ];

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
