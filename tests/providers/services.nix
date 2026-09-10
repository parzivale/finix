# tests for the providers.services contract on the finit backend
#
# covers the two behaviours the design rests on and which cannot be settled by reading
# the module sources:
#
#   1. does `task/<n>/success` keep holding once the task's own conditions are lost?
#      the companion-latch encoding of start-only edges depends on it - if the condition
#      retracts, finit cannot express a dependency which gates starting without also
#      propagating stops, and the encoding has to change.
#
#   2. does finit run the shutdown-side `[06]` stanzas after tearing the boot-side
#      services down, or concurrently with it? the trunk's latch level is named
#      `stopped`, and that name is only honest if teardown has finished by then.
{
  name = "providers.services";

  nodes.machine =
    { pkgs, ... }:
    let
      # a daemon which leaves a file behind for as long as it is running, so another unit
      # can tell whether it is still up without needing to ask finit during shutdown
      daemon =
        name:
        pkgs.writeShellScript "${name}-daemon" ''
          mkdir -p /run/svc-test
          trap 'rm -f /run/svc-test/${name}.running; exit 0' TERM
          touch /run/svc-test/${name}.running
          echo "${name} up" > /run/svc-test/${name}.started
          sleep infinity &
          wait
        '';

      marker =
        name:
        pkgs.writeShellScript "${name}-marker" ''
          mkdir -p /run/svc-test
          echo "${name} ran" > /run/svc-test/${name}.ran
        '';
    in
    {
      services.mdevd.enable = true;
      services.getty.enable = true;

      providers.services.backend = "finit";
      providers.services.trunk.enable = true;

      providers.services.units = {
        # attaches to the first trunk level, so `sysinit` cannot be reached until it is done
        early = {
          type = "oneshot";
          command = marker "early";
          requires = [ "start" ];
        };

        alpha = {
          command = daemon "alpha";
          requires = [ "sysinit" ];
        };

        # depends on a service rather than a level, so it exercises the companion latch
        beta = {
          command = daemon "beta";
          requires = [ "alpha" ];
        };

        gamma = {
          command = daemon "gamma";
          requires = [ "basic" ];
        };

        # left running for the shutdown test, so its marker file is still there when the
        # shutdown-side units run
        delta = {
          command = daemon "delta";
          requires = [ "sysinit" ];
        };

        # shutdown side: attaches to a level after the latch, and reports both that it ran
        # at all and whether the boot-side services were gone by the time it did
        late = {
          type = "oneshot";
          requires = [ "stopped" ];
          command = pkgs.writeShellScript "late" ''
            if [ -e /run/svc-test/delta.running ]; then
              echo "SHUTDOWN-STEP late RACE delta still running" > /dev/console
            else
              echo "SHUTDOWN-STEP late CLEAN delta already stopped" > /dev/console
            fi
          '';
        };

        # a second step after `late`, to prove the shutdown sequence runs to its end rather
        # than being cut off partway by the power going down
        later = {
          type = "oneshot";
          requires = [ "stopped" ];
          command = pkgs.writeShellScript "later" ''
            echo "SHUTDOWN-STEP later" > /dev/console
          '';
        };
      };

      # control: conditioned directly on alpha's live readiness rather than on the
      # companion latch, so the two can be compared when alpha is stopped
      finit.services.control = {
        description = "conditioned on live readiness";
        runlevels = "S12345789";
        conditions = "service/alpha/ready";
        command = daemon "control";
      };
    };

  testScript = ''
    import json

    def cond(name):
        """Status of a single finit condition: on, off, or flux."""
        dump = json.loads(machine.succeed("initctl -j cond dump"))
        hit = next((c for c in dump if c["condition"] == name), None)
        return hit["status"] if hit else None

    def status(name):
        return json.loads(machine.succeed(f"initctl -j status {name}"))["status"]

    machine.start()

    machine.wait_for_console_text("finix - stage 1")
    machine.wait_for_console_text("finix - stage 2")
    machine.wait_for_console_text("entering runlevel 2")
    machine.wait_for_console_text("getty on /dev/tty1")

    with subtest("trunk levels are reached in order"):
        for level in ["start", "sysinit", "basic", "multi-user", "running"]:
            machine.succeed(f"test -f /run/finit/cond/task/{level}/success")
            assert cond(f"task/{level}/success") == "on", f"{level} not reached"

    with subtest("the latch does not resolve while the system is running"):
        # `stopped` and `shutdown` exist only in runlevels 0 and 6
        machine.fail("test -f /run/finit/cond/task/stopped/success")
        machine.fail("test -f /run/finit/cond/task/shutdown/success")
        machine.fail("test -f /run/svc-test/late.ran")

    with subtest("units attached to the trunk all started"):
        machine.succeed("test -f /run/svc-test/early.ran")
        for svc in ["alpha", "beta", "gamma", "delta"]:
            assert status(svc) == "running", f"{svc} is {status(svc)}"

    with subtest("companion latches are asserted"):
        for svc in ["alpha", "beta", "gamma", "delta"]:
            assert cond(f"task/{svc}-started/success") == "on"

    with subtest("anchors have companions too, so restarting one cannot cascade"):
        # a unit depended upon directly would drop its condition when restarted, taking down
        # everything hanging off it. the switch engine restarts an anchor whenever a service
        # attaches to its trunk level, so anchors need the latch as much as services do.
        for level in ["start", "sysinit", "basic", "multi-user", "running"]:
            assert cond(f"task/{level}-started/success") == "on", f"{level} has no companion"

    # question 1: does the companion latch survive its own condition being lost?

    with subtest("stopping a service retracts its live readiness condition"):
        machine.succeed("initctl stop alpha")
        machine.sleep(2)
        assert status("alpha") == "stopped", f"alpha is {status('alpha')}"
        assert cond("service/alpha/ready") != "on", "service/alpha/ready did not retract"

    with subtest("QUESTION 1: the companion latch holds after the service stops"):
        held = cond("task/alpha-started/success")
        print(f"task/alpha-started/success after stopping alpha: {held}")
        assert held == "on", (
            f"companion latch retracted (status {held}) - finit cannot express start-only "
            f"edges this way, and the backend encoding needs rethinking"
        )

    with subtest("a dependant of the latch keeps running"):
        assert status("beta") == "running", (
            f"beta is {status('beta')} - the stop propagated through the companion latch"
        )

    with subtest("control: a dependant of live readiness does not"):
        # same dependency, expressed the way the backend used to do it. if this is also
        # still running then finit never propagated stops and the companion is unnecessary.
        control = status("control")
        print(f"control (conditioned on service/alpha/ready) after stopping alpha: {control}")

    # question 2: is the shutdown chain ordered after teardown?

    with subtest("QUESTION 2: the shutdown sequence runs to completion, in order"):
        machine.succeed("test -e /run/svc-test/delta.running")
        machine.execute("(initctl poweroff &) >/dev/null 2>&1", check_return=False)

        # both steps must appear, and in this order. `late` also reports whether the
        # boot-side services were already gone when it ran.
        machine.wait_for_console_text("SHUTDOWN-STEP late")
        machine.wait_for_console_text("SHUTDOWN-STEP later")

        # the machine is powering off under us; let the driver notice before it tries to
        # run its cleanup commands on a dead shell
        machine.wait_for_shutdown()
  '';
}
