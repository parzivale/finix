# the same claims as ordering and shutdown, made hard to satisfy by accident
#
# The other core tests use three units and no delays, which a backend can pass by starting
# everything at once and getting lucky - a graph that is never under pressure does not
# distinguish an implementation that waits from one that happens to be fast enough. Every real
# bug found in this suite so far was a race that only showed when the timing changed: finit's
# shutdown sequence was outrun by the power-off and passed until a machine with fewer services
# lost the race; runit and s6-rc ran the shutdown side at boot and nothing noticed.
#
# So this one is built to lose those races if they exist. Units take seconds to become ready,
# the graph forks and rejoins so there is no single order to fall into, and the shutdown side
# sleeps long enough that an init which does not wait will be caught powering off mid-sequence.
#
# What it asserts is the partial order, not a total one: two units on separate branches may
# start in either order, and demanding one would be asserting an implementation detail. Every
# declared edge, though, must hold.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };

  sleep = lib.getExe' pkgs.coreutils "sleep";
  touch = lib.getExe' pkgs.coreutils "touch";

  # records the moment it starts, then takes its time becoming ready. Dependants are gated on
  # the live file, not on the process existing, so a backend which treats spawning as readiness
  # starts them too early and the recorded order shows it.
  slow = name: delay: {
    type.service = {
      command = pkgs.writeShellScript "stress-${name}" ''
        ${coreLib.preamble}
        echo ${name} >> ${coreLib.markerDir}/order
        ${sleep} ${toString delay}
        ${touch} ${coreLib.markerDir}/${name}.live
        exec ${sleep} infinity
      '';
      readiness.waitFor.path.path = "${coreLib.markerDir}/${name}.live";
    };
  };

  # a shutdown step which is slow enough to be cut short by an init that does not wait for it
  downStep =
    name: delay:
    pkgs.writeShellScript "stress-down-${name}" ''
      ${sleep} ${toString delay}
      ${coreLib.preamble}
      ${touch} ${coreLib.markerDir}/${name}.down
      echo "STRESS-DOWN ${name}" > /dev/console
    '';

  # every edge the configuration below declares, as the test will check it
  edges = [
    [
      "a1"
      "a2"
    ]
    [
      "a2"
      "a3"
    ]
    [
      "b1"
      "b2"
    ]
    [
      "a3"
      "join"
    ]
    [
      "b2"
      "join"
    ]
    [
      "join"
      "f1"
    ]
    [
      "join"
      "f2"
    ]
  ];
in
{
  name = "providers.stress-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        # two branches of different depth and different timing, so neither finishing first is
        # a matter of which was declared first
        a1 = slow "a1" 2 // {
          requires = [ "sysinit" ];
        };
        a2 = slow "a2" 1 // {
          requires = [ "a1" ];
        };
        a3 = slow "a3" 1 // {
          requires = [ "a2" ];
        };

        b1 = slow "b1" 3 // {
          requires = [ "sysinit" ];
        };
        b2 = slow "b2" 1 // {
          requires = [ "b1" ];
        };

        # the join: may only start once both branches are live, and the branches are timed so
        # that the shorter one finishes well before the longer
        join = slow "join" 1 // {
          requires = [
            "a3"
            "b2"
          ];
        };

        # and a fan-out, so the last thing to start is not also the only thing
        f1 = slow "f1" 0 // {
          requires = [ "join" ];
        };
        f2 = slow "f2" 0 // {
          requires = [ "join" ];
        };

        # the shutdown side: two units on the latch level and one on the level after it. The
        # pair are siblings, so nothing orders them against each other - but both must have
        # finished before the next level runs, and that is what the last one reports.
        down-a1 = {
          requires = [ "stopped" ];
          type.oneshot.command = downStep "down-a1" 2;
        };

        down-a2 = {
          requires = [ "stopped" ];
          type.oneshot.command = downStep "down-a2" 2;
        };

        down-last = {
          requires = [ "shutdown" ];
          type.oneshot.command = pkgs.writeShellScript "stress-down-last" ''
            ${sleep} 1
            seen=0
            for m in down-a1 down-a2; do
              if [ -e ${coreLib.markerDir}/"$m".down ]; then
                seen=$((seen + 1))
              fi
            done
            echo "STRESS-DOWN-LAST saw:$seen" > /dev/console
          '';
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("every unit started"):
        machine.wait_until_succeeds(
            "test $(wc -l < ${coreLib.markerDir}/order) -eq 8", timeout=180
        )

    with subtest("and every declared edge held, under delays long enough to expose one that did not"):
        order = machine.succeed("cat ${coreLib.markerDir}/order").split()
        at = {name: i for i, name in enumerate(order)}

        for dep, unit in ${builtins.toJSON edges}:
            assert dep in at, f"{dep} never started: {order}"
            assert unit in at, f"{unit} never started: {order}"
            assert at[dep] < at[unit], (
                f"{unit} started before {dep}, which it requires - order was {order}"
            )

    with subtest("nothing on the shutdown side ran while the system was up"):
        for m in ["down-a1", "down-a2"]:
            machine.fail(f"test -e ${coreLib.markerDir}/{m}.down")

    machine.execute("(poweroff &) >/dev/null 2>&1", check_return=False)

    with subtest("the shutdown sequence ran to completion, not as far as the power-off allowed"):
        # five seconds of sleeps across three steps. An init which starts the sequence and
        # carries on powering off loses the tail of it, which is what this is here to catch.
        machine.wait_for_console_text("STRESS-DOWN down-a1")
        machine.wait_for_console_text("STRESS-DOWN down-a2")

        # the claim that orders them: the later level ran only once both units attached to the
        # earlier one had finished, and says so itself rather than leaving it to be inferred
        # from the order two console lines were read in
        machine.wait_for_console_text("STRESS-DOWN-LAST saw:2")

    with subtest("and the machine still powers off"):
        machine.wait_for_shutdown()
  '';
}
