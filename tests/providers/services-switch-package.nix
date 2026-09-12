# switching into a separate configuration which adds a package, on runit
#
# tests/providers/services-switch.nix covers the engine's arithmetic - which units it starts
# and stops between two generations. This covers the other half, and the half anyone doing it
# by hand tries first: add a package, switch, expect the command to be there.
#
# The second generation is a whole configuration rather than a specialisation, which is the
# case that actually happens: a toplevel built separately, named by path, that the running
# system has never heard of. A specialisation is prepared in advance by the generation running
# it, and proves less for that reason.
#
# runit rather than finit on purpose. finit reconciles from its own configuration, so a switch
# there is nearly a no-op; runit knows nothing about generations, so what makes this work is
# the activation script rewriting /etc and /run/current-system, and the contract's own engine
# reconciling the units.
let
  pkgs = import (import ../../lon.nix).nixpkgs { };
  inherit (pkgs) lib;

  testLib = import ../lib {
    inherit pkgs;
    inherit (pkgs) lib;
  };

  # what both generations are, so they cannot drift apart
  base = {
    services.mdevd.enable = true;
    services.getty.enable = true;

    providers.services.backend = "runit";
  };

  # and the one thing that differs
  next = {
    imports = [ base ];
    environment.systemPackages = [ pkgs.cowsay ];
  };

  nextSystem = (testLib.evalNode "machine" next).config.system.topLevel;
in
{
  name = "providers.services-switch-package";

  nodes.machine =
    { ... }:
    {
      imports = [ base ];
      environment.systemPackages = [ pkgs.hello ];
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e /etc/passwd", timeout=240)

    with subtest("the first generation is up, with what it ships and nothing else"):
        # hello is in this generation and cowsay is not, so a switch that works shows up as
        # cowsay appearing rather than as a path changing somewhere
        machine.succeed("hello")
        machine.fail("cowsay moo")

        before = machine.succeed("readlink -f /run/current-system").strip()
        print(f"before: {before}")

    with subtest("switching into a configuration built separately"):
        # named by store path: this system has no link to it and did not boot knowing it
        out = machine.succeed(
            "${nextSystem}/bin/switch-to-configuration test 2>&1"
        )
        print(out)

    with subtest("the new package is there, and the system moved"):
        machine.succeed("cowsay moo")

        after = machine.succeed("readlink -f /run/current-system").strip()
        print(f"after: {after}")
        assert after == "${nextSystem}", f"/run/current-system is {after}"
        assert after != before, "/run/current-system did not move"

    with subtest("the machine is still running, not just reconfigured"):
        # asked without the backend's own tooling - the latch files and PID 1 answer it
        machine.succeed("test -e /run/providers-services/running.ready")
        machine.succeed("test -e /run/providers-services/multi-user.ready")

        pid1 = machine.succeed("ps -p 1 -o comm=").strip()
        print(f"pid 1: {pid1}")
        assert pid1 == "runit", f"PID 1 is {pid1}, not runit"

    machine.shutdown()
  '';
}
