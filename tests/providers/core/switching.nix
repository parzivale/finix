# switching between two whole configurations moves only what changed
#
# The question is not "did the switch work" but "did it move only what it had to". A switch
# which restarts everything looks identical from outside to one which restarts nothing, until
# you ask what happened to a service that was meant to be left alone - so the assertion that
# matters is the one about `keeper` keeping its pid.
#
# Nothing here is a specialisation: the second generation is a whole configuration, built
# separately and named by store path, exactly as `nix build` would produce it. On backends with
# no notion of generations at all - runit has none - everything visible is the contract's engine
# reconciling, not a supervisor being clever on its own.
{
  pkgs,
  lib,
  testLib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };

  base = {
    imports = [ (import ./base.nix { inherit backend coreLib; }) ];

    providers.services.units = {
      # in both generations, unchanged: nothing about it differs, so nothing should happen to it
      keeper = {
        type.service.command = coreLib.daemon "keeper";
        requires = [ "sysinit" ];
      };
    };
  };

  next = {
    imports = [ base ];

    providers.services.units = {
      # gone in the second generation
      goner.enable = lib.mkForce false;

      # and one which only exists there
      newcomer = {
        type.service.command = coreLib.daemon "newcomer";
        requires = [ "sysinit" ];
      };
    };
  };

  nextSystem = (testLib.evalNode "machine" next).config.system.topLevel;
in
{
  name = "providers.switching-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ base ];

      providers.services.units.goner = {
        type.service.command = coreLib.daemon "goner";
        requires = [ "sysinit" ];
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("the first generation's services are up"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-keeper'", timeout=60)
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-goner'", timeout=60)

        keeper_before = pid_of("keeper")
        assert pid_of("newcomer") is None, "newcomer is running before the switch"

    with subtest("switching into a configuration which drops one and adds another"):
        # teed to the console as well as captured: a switch which hangs leaves the captured
        # output unread until the command returns, which is never - so on the console is the
        # only place the progress of a hanging switch can be seen. pipefail keeps tee from
        # swallowing a failure.
        out = machine.succeed(
            "set -o pipefail; ${nextSystem}/bin/switch-to-configuration test 2>&1 | tee /dev/console"
        )
        print(out)

        # what the engine says it did, which should name both and neither of the others
        assert "goner" in out, f"the engine did not mention goner: {out}"
        assert "newcomer" in out, f"the engine did not mention newcomer: {out}"

    with subtest("the one that went away is down"):
        machine.wait_until_fails("pgrep -f '[f]inix-daemon-goner'", timeout=60)

    with subtest("the one that arrived is up"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-newcomer'", timeout=60)

    with subtest("and the one that did not change was left alone"):
        # the whole point: the same process, not a restarted one. An engine which cannot tell
        # the difference would have taken this down and brought it back with a new pid.
        keeper_after = pid_of("keeper")

        assert keeper_after is not None, "keeper is not running after the switch"
        assert keeper_after == keeper_before, (
            f"keeper was restarted: {keeper_before} -> {keeper_after}"
        )

    with subtest("the machine is still up afterwards"):
        # a switch which took the trunk down with it would still have passed everything above
        machine.succeed("test -e ${coreLib.bootedMarker}")

    machine.shutdown()
  '';
}
