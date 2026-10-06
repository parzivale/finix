# `reboot` restarts the machine, rather than merely stopping it
#
# This is the test whose absence let a backend power off when asked to reboot, for months, on
# real hardware. `core/shutdown.nix` next door asserts that `poweroff` powers the machine off,
# and it passed throughout - because the failure turned reboot *into* poweroff, which is the one
# outcome that test was happy with. The suite had no way to tell the two apart, so a backend
# which could only do one of them looked correct.
#
# The distinction is not observable from inside the guest: the last thing either path does is
# reboot(2), and nothing in userspace runs afterwards to report which argument it was given. Nor
# is it observable from the driver, which waits on the QEMU process and sees it exit either way.
#
# The kernel says it, though, and says it on the console. `kernel_restart()` prints "Restarting
# system." and `kernel_power_off()` prints "Power down." - the last two lines either path ever
# produces, emitted after userspace is gone and before the machine stops. Waiting for the first
# is therefore an assertion about which syscall was reached, which is exactly the claim, and it
# holds for every implementation because they all have to end there.
#
# A failure here is a timeout rather than a wrong answer: a machine which powers off never
# prints the line being waited for.
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
  name = "providers.reboot-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        # something for the way down to have stopped, so this is a real shutdown sequence and
        # not an empty one that happens to reach the syscall.
        running-daemon = {
          type.service.command = coreLib.daemon "running-daemon";
          requires = [ "sysinit" ];
        };

        # the shutdown side runs on a reboot too, which is not obvious and is worth pinning: on
        # every thin backend it is the same program reaching the same lowered script, with only
        # the final syscall differing, and a backend which skipped it on one path and not the
        # other would still pass the poweroff test next door.
        on-the-way-down = {
          requires = [ "stopped" ];
          type.oneshot.command = pkgs.writeShellScript "reboot-down" ''
            echo "CORE-REBOOT-DOWN" > /dev/console
          '';
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("the machine is up, with its boot-side daemon running"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-running-daemon'", timeout=60)

    # backgrounded and unchecked, for `core/shutdown.nix`'s reason: this takes the driver's own
    # shell down with the machine, so there is nothing left to report an exit status to. A bare
    # `reboot` rather than any particular init's command, which is the assertion that the
    # selected backend's own is what it reaches.
    machine.execute("(reboot &) >/dev/null 2>&1", check_return=False)

    with subtest("the shutdown side runs on the way to a reboot"):
        machine.wait_for_console_text("CORE-REBOOT-DOWN")

    with subtest("and the kernel is asked to restart, not to power down"):
        # the whole test. "Power down." here instead means the machine was asked to do the other
        # thing, and this waits until the suite's timeout rather than returning.
        machine.wait_for_console_text("Restarting system")
  '';
}
