# a unit starts only after everything it requires has started
#
# The contract's central promise, and the one each implementation arrives at differently: finit
# conditions, dinit dependencies, s6-rc's compiled graph, and on runit nothing at all - runsvdir
# starts every service directory at once, and the ordering is synthesised out of latch files.
#
# A chain of three is enough to tell a graph that holds from one that does not. Each unit
# appends its name to a single file as it starts, so the file is the order the machine actually
# used, and the assertion is that it is the order that was asked for.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };
in
{
  name = "providers.ordering-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        first = {
          type.service.command = coreLib.recorder "first";
          requires = [ "sysinit" ];
        };

        second = {
          type.service.command = coreLib.recorder "second";
          requires = [ "first" ];
        };

        third = {
          type.service.command = coreLib.recorder "third";
          requires = [ "second" ];
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("every unit in the chain started"):
        machine.wait_until_succeeds(
            "test $(wc -l < ${coreLib.markerDir}/order) -eq 3", timeout=120
        )

    with subtest("and each one started after the unit it requires"):
        # the whole claim. On runit this is the synthesised edges holding despite runsvdir
        # doing its best to start all three at once.
        order = machine.succeed("cat ${coreLib.markerDir}/order").split()
        assert order == ["first", "second", "third"], f"started in the order {order}"

    machine.shutdown()
  '';
}
