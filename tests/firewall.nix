# test for the providers.firewall module
#
# verifies that the nftables backend correctly allows and blocks traffic
#
# node ip assignments (sorted alphabetically):
#   client   -> 192.168.1.1
#   nftables -> 192.168.1.2
{
  name = "firewall";

  nodes.client =
    { pkgs, ... }:
    {
      providers.services.backend = "finit";

      services.getty.enable = true;
      services.mdevd.enable = true;

      environment.systemPackages = [ pkgs.nmap ];
    };

  # nftables backend: packets dropped, ping blocked (defaults)
  nodes.nftables =
    { pkgs, ... }:
    {
      providers.services.backend = "finit";

      services.getty.enable = true;
      services.mdevd.enable = true;
      services.nftables.enable = true;

      providers.firewall.allowedTCPPorts = [ 8080 ];

      environment.systemPackages = [ pkgs.nmap ];

      # contract units rather than finit stanzas, like everything else the machine runs. On
      # finit a unit still lowers to a service of the same name, so `initctl status` below
      # answers about these exactly as it did before.
      providers.services.units.allowed-port = {
        description = "listener on allowed port";
        requires = [ "basic" ];
        type.service.command = "${pkgs.nmap}/bin/ncat -k -l 8080";
      };

      providers.services.units.blocked-port = {
        description = "listener on blocked port";
        requires = [ "basic" ];
        type.service.command = "${pkgs.nmap}/bin/ncat -k -l 8081";
      };
    };

  testScript = ''
    import datetime

    start_all()

    client.wait_for_console_text("entering runlevel 2")
    nftables.wait_for_console_text("entering runlevel 2")

    # the listeners are up, asked by connecting to them rather than by asking the supervisor.
    # `initctl status <name> | grep running` was the old phrasing and it no longer matches:
    # these are contract units, and what the test needs to know is that something is accepting
    # on the port - which is also the only part of it the later subtests depend on.
    nftables.wait_until_succeeds("ncat -z -w 3 127.0.0.1 8080", timeout=datetime.timedelta(seconds=30))
    nftables.wait_until_succeeds("ncat -z -w 3 127.0.0.1 8081", timeout=datetime.timedelta(seconds=30))

    # wait until the ruleset is actually loaded before probing
    nftables.wait_until_succeeds("nft list table inet nixos-fw", timeout=datetime.timedelta(seconds=30))

    with subtest("nftables: ping is blocked by default"):
        client.fail("ping -c 1 -W 3 192.168.1.2")

    with subtest("nftables: loopback is trusted"):
        nftables.succeed("ncat -z -w 3 127.0.0.1 8081")

    with subtest("nftables: deletions state file is populated"):
        nftables.succeed("grep -q 'delete table inet nixos-fw' /var/lib/nftables/deletions.nft")

    with subtest("nftables: allowed tcp port is reachable"):
        client.succeed("ncat -z -w 3 192.168.1.2 8080")

    with subtest("nftables: blocked tcp port is unreachable"):
        client.fail("ncat -z -w 3 192.168.1.2 8081")

    with subtest("nixos-firewall-tool: detects the nftables backend"):
        nftables.succeed("nixos-firewall-tool show | grep -q 'table inet nixos-fw'")

    with subtest("nixos-firewall-tool: opens a port at runtime"):
        nftables.succeed("nixos-firewall-tool open tcp 8081")
        client.succeed("ncat -z -w 3 192.168.1.2 8081")

    with subtest("nixos-firewall-tool: reset closes the port again"):
        nftables.succeed("nixos-firewall-tool reset")
        client.fail("ncat -z -w 3 192.168.1.2 8081")

    # the subtest which stood here left runlevel 2 to stop the firewall, because the ruleset was
    # loaded by a finit task pinned to that runlevel. It is a contract unit now: it comes up
    # with the trunk, and the unloading is `nftables-flush` on the shutdown side, which runs
    # when the machine goes down rather than when it changes runlevel. There is no runlevel to
    # leave any more, and that the shutdown side runs at all is what tests/providers/core's
    # shutdown test covers on all four implementations.
    #
    # What can still be said here is that the two halves are inverses, which is the property
    # that subtest was really checking - so it is checked directly.
    with subtest("unloading the ruleset removes the rules and empties the state file"):
        # read out of the shutdown sequence rather than hardcoded, which also asserts the
        # flush is wired into it: the shutdown side is not one stanza per unit but a single
        # ordered script, and on finit it is a HOOK_SHUTDOWN hook. Finding nftables-stop in
        # there and running it is running exactly what a poweroff would.
        flush = nftables.succeed(
            "grep -o '/nix/store/[^ ]*-nftables-stop' "
            "/etc/finit/hook/sys/shutdown/providers-services-shutdown | head -1"
        ).strip()
        nftables.succeed(flush)

        nftables.fail("nft list table inet nixos-fw")
        client.succeed("ncat -z -w 3 192.168.1.2 8081")
        nftables.succeed("test ! -s /var/lib/nftables/deletions.nft")

    client.shutdown()
    nftables.shutdown()
  '';
}
