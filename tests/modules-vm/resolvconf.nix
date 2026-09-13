# a lease arrives and resolvconf writes it down
#
# This covers the resolvconf path specifically, and not "does DNS work": dhcpcd writes
# /etc/resolv.conf through its own hook when no resolvconf binary is on its PATH, so a test
# which only checked for a nameserver would pass whether the resolver was configured or not.
# It did, when this was first written.
#
# The case that actually depends on `programs.resolvconf.enable` is iwd, which does its own
# DHCP and is handed `NameResolvingService = "none"` when no resolver exists - so a wifi
# machine gets an address, a route, and no name resolution at all. That is an evaluation-level
# fact rather than something a VM without simulated wifi can show, so it is asserted in
# tests/modules; this proves the other half, that what resolvconf is handed reaches the file.
{
  pkgs,
  lib,
  backend,
  ...
}:
{
  name = "modules.resolvconf-${backend}";

  nodes.server =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      providers.services.units.dnsmasq = {
        description = "dhcp and dns for the test network";
        requires = [ "basic" ];

        type.service.command = pkgs.writeShellScript "dnsmasq" ''
          exec ${lib.getExe pkgs.dnsmasq} --keep-in-foreground \
            --interface=eth0 --bind-interfaces \
            --dhcp-range=192.168.1.100,192.168.1.200,12h \
            --dhcp-option=option:dns-server,192.168.1.2
        '';
      };
    };

  nodes.client =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      # the line micolash is missing
      programs.resolvconf.enable = true;

      services.dhcpcd.enable = true;

      # the harness configures eth0 statically; dhcpcd has to be the one driving it here
      programs.ifupdown-ng.auto = lib.mkForce [ ];
    };

  testScript = ''
    start_all()

    server.wait_until_succeeds("pgrep -x dnsmasq", timeout=120)

    with subtest("the client takes a lease"):
        client.wait_until_succeeds("ip -4 addr show eth0 | grep -q 192.168.1.1", timeout=120)

    with subtest("and the nameserver from it reaches /etc/resolv.conf"):
        client.wait_until_succeeds("grep -q 'nameserver 192.168.1.2' /etc/resolv.conf", timeout=60)

    client.shutdown()
    server.shutdown()
  '';
}
