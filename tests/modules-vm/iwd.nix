# iwd associates, configures the link, and hands the nameservers somewhere
#
# Nothing else in the suite exercises iwd's behaviour, which is how a laptop came to have an
# address and no name resolution while every test passed: iwd does its own DHCP and is told
# `NameResolvingService = "none"` whenever `programs.resolvconf.enable` is false, which is its
# default. That is visible in the generated main.conf, but what a machine does with it is not.
#
# So the machine builds itself a radio. mac80211_hwsim gives the kernel two virtual wireless
# devices on one host; hostapd runs an access point on the second, dnsmasq serves DHCP and DNS
# behind it, and iwd is asked to connect to it on the first - which is as close to the real
# thing as a VM gets without hardware.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ../providers/core/lib.nix { inherit pkgs lib; };

  ssid = "finix-test";

  hostapdConf = pkgs.writeText "hostapd.conf" ''
    interface=wlan1
    driver=nl80211
    ssid=${ssid}
    hw_mode=g
    channel=1
  '';
in
{
  name = "modules.iwd-${backend}";

  nodes.machine =
    { config, ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      # two virtual radios: wlan0 for iwd, wlan1 for the access point
      boot.kernelModules = [ "mac80211_hwsim" ];

      services.dbus.enable = true;
      services.iwd.enable = true;

      # the line whose absence leaves a wifi machine with no resolver
      programs.resolvconf.enable = true;

      # iwd is told to leave the second radio alone.
      #
      # It manages every phy it finds, and this machine is the one case a real one is not: the
      # access point it associates with is on the same host. iwd listed wlan1 as a device in
      # "ap" mode and cleared its address roughly once a second - the address was re-added, and
      # removed again, so dnsmasq could not bind its DHCP socket and the station associated and
      # then deauthenticated thirty seconds later with no lease. Only the command is replaced,
      # so the generated main.conf, the resolvconf on its path and its place in the trunk are
      # still the module's.
      providers.services.units.iwd.type.service.command = lib.mkForce (
        pkgs.writeShellScript "iwd" ''
          # restart trigger: ${config.services.iwd.configFile}
          exec ${config.services.iwd.package}/libexec/iwd --nointerfaces=wlan1
        ''
      );

      environment.systemPackages = [
        pkgs.iwd
        pkgs.iw
        pkgs.iproute2
      ];

      # the access point the machine will talk to, on its own radio
      providers.services.units.access-point = {
        description = "an access point on the second radio";
        requires = [ "basic" ];

        type.service.command = pkgs.writeShellScript "access-point" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.iproute2
              pkgs.coreutils
            ]
          }:$PATH

          # wait for hwsim to have created the radios
          until ip link show wlan1 >/dev/null 2>&1; do sleep 0.5; done

          exec ${lib.getExe' pkgs.hostapd "hostapd"} ${hostapdConf}
        '';
      };

      # the address for the access point's own interface, held rather than assigned.
      #
      # Assigning it once does not survive: hostapd brings the interface up as part of its own
      # startup, and an address put there before that goes with it. The symptom is at the far
      # end of the machine and says nothing about the cause - dnsmasq logs "DHCP packet
      # received on wlan1 which has no address", nothing answers the lease, and iwd
      # deauthenticates thirty seconds later "by local choice".
      #
      # So this re-asserts the address for as long as it runs, and reports ready only once the
      # address is actually on the interface - which is what keeps dnsmasq, which binds its
      # DHCP socket to the interface at startup, from starting too early.
      providers.services.units.access-point-address = {
        description = "keep an address on the access point interface";
        requires = [ "access-point" ];

        type.service = {
          command = pkgs.writeShellScript "ap-address" ''
            export PATH=${
              lib.makeBinPath [
                pkgs.iproute2
                pkgs.coreutils
              ]
            }:$PATH

            while :; do
              if ! ip -4 addr show wlan1 2>/dev/null | grep -q "10\.9\.9\.1/24"; then
                ip addr replace 10.9.9.1/24 dev wlan1 2>/dev/null || true
              fi
              sleep 1
            done
          '';

          readiness = [
            {
              waitFor.check.command = pkgs.writeShellScript "ap-address-ready" ''
                # an explicit PATH, because a readiness check runs with whatever environment the
                # implementation gives it and that is not required to include coreutils. Without
                # this, `sleep` was simply not found: every iteration failed instantly, the
                # bound below was spent in milliseconds, and the check reported "not ready"
                # before the unit it is checking had assigned anything. dinit failed here while
                # finit passed, which looked like an ordering difference between backends and
                # was nothing of the sort.
                export PATH=${
                  lib.makeBinPath [
                    pkgs.iproute2
                    pkgs.coreutils
                    pkgs.gnugrep
                  ]
                }:$PATH

                # bounded: a check which never returns stalls everything behind it until the
                # start timeout, and a failing DHCP is a better failure than a stalled trunk.
                n=0
                until ip -4 addr show wlan1 2>/dev/null | grep -q "10\.9\.9\.1/24"; do
                  n=$((n + 1))
                  [ "$n" -ge 120 ] && exit 1
                  sleep 0.5
                done
              '';
            }
          ];
        };
      };

      providers.services.units.access-point-dhcp = {
        description = "dhcp and dns behind the access point";
        requires = [ "access-point-address" ];

        # the lease file lives in /run rather than dnsmasq's default /var/lib/misc, because
        # nothing in the tree creates that directory: dnsmasq died on "cannot open or create
        # lease file" on three of the four backends, and a machine whose access point cannot
        # write a lease has nothing to hand the station.
        type.service.command = pkgs.writeShellScript "ap-dhcp" ''
          exec ${lib.getExe pkgs.dnsmasq} --keep-in-foreground \
            --interface=wlan1 --bind-interfaces \
            --dhcp-leasefile=/run/dnsmasq.leases \
            --dhcp-range=10.9.9.100,10.9.9.200,12h \
            --dhcp-option=option:dns-server,10.9.9.1
        '';
      };

      providers.services.units.booted = coreLib.bootedUnit;
      providers.services.tmpfiles.rules = [
        {
          type = "directory";
          path = coreLib.markerDir;
          mode = "1777";
        }
      ];
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e ${coreLib.bootedMarker}", timeout=120)

    with subtest("the radios exist and the access point is up"):
        machine.wait_until_succeeds("ip link show wlan0", timeout=60)
        machine.wait_until_succeeds("pgrep -x hostapd", timeout=60)
        machine.wait_until_succeeds("pgrep -x dnsmasq", timeout=60)

    with subtest("iwd associates with it"):
        machine.wait_until_succeeds("iwctl device list | grep -q wlan0", timeout=60)
        machine.succeed("iwctl station wlan0 scan || true")
        machine.wait_until_succeeds(
            "iwctl station wlan0 get-networks | grep -q ${ssid}", timeout=60
        )
        # retried rather than asserted once: association is a radio exchange with a timeout at
        # the other end of it, and a single auth attempt landing while hostapd is settling
        # fails the whole test for a reason that has nothing to do with the init system.
        #
        # The state is matched with the column in front of it because "disconnected" contains
        # "connected": a plain grep passed on the very first try against a station that had
        # never associated, and the test then failed two subtests later on the address it was
        # never going to get.
        machine.wait_until_succeeds(
            "iwctl station wlan0 show | grep -qE 'State +connected' "
            "|| iwctl station wlan0 connect ${ssid}",
            timeout=120,
        )

    with subtest("iwd configures the link itself"):
        machine.wait_until_succeeds("ip -4 addr show wlan0 | grep -q 10.9.9.", timeout=60)

    with subtest("and the nameservers reach /etc/resolv.conf"):
        # the whole point: iwd is handed NameResolvingService = resolvconf, and this is what
        # that is worth. With the option off it is told "none" and writes nothing at all.
        machine.wait_until_succeeds("grep -q 'nameserver 10.9.9.1' /etc/resolv.conf", timeout=60)

    machine.shutdown()
  '';
}
