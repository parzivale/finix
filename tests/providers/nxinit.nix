# the providers.services contract, driven on nxinit as PID 1
#
# nxinit is the thinnest backend here: it blocks three signals, execs one compiled-in child,
# reaps what lands on pid 1, and answers a signal each for reboot and poweroff. Everything the
# contract offers above that is finix's, in shell, exactly as it is for sinit - so this test is
# sinit's questions asked of a different init.
#
# Two things are specific to this backend and are the reason the test exists at all:
#
#   1. the exec. Hare's `os::exec` runs a descriptor through execveat(2) rather than taking a
#      path, so a `#!` script is handed /dev/fd/N - which udev creates, long after this point.
#      rc.init is a shell script, so a boot that reaches a prompt at all is the whole of the
#      evidence that the `pre` op supplying /dev/fd ran and worked.
#
#   2. the shutdown. nxinit answers USR1 and USR2 by spawning rcshutdown rather than calling
#      reboot(2) on the spot, which is what gives the shutdown side anywhere to run. Upstream
#      does not do that and a machine built on upstream would reboot with nothing stopped - so
#      the ordered shutdown units below are not a nicety, they are the check that the patch is
#      in the binary the machine actually booted.
{
  name = "providers.services-nxinit";

  nodes.machine =
    { pkgs, ... }:
    let
      daemon =
        name:
        pkgs.writeShellScript "${name}-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          mkdir -p /run/svc-test
          touch /run/svc-test/${name}.running
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
    in
    {
      services.mdevd.enable = true;

      providers.services.backend = "nxinit";

      providers.services.units = {
        early = {
          type.oneshot.command = pkgs.writeShellScript "early" ''
            export PATH=${pkgs.coreutils}/bin:$PATH
            mkdir -p /run/svc-test
            touch /run/svc-test/early.ran
          '';
          requires = [ "start" ];
        };

        alpha = {
          type.service.command = daemon "alpha";
          requires = [ "sysinit" ];
        };

        # a dependent of a service, to show the latch a supervised unit writes is what
        # releases what waits on it
        beta = {
          type.service.command = daemon "beta";
          requires = [ "alpha" ];
        };

        gamma = {
          type.service.command = daemon "gamma";
          requires = [ "basic" ];
        };

        # the shutdown side, at two trunk positions so their order is unambiguous. Reaching
        # these at all means rcshutdown was spawned rather than reboot(2) called directly.
        late = {
          requires = [ "stopped" ];
          type.oneshot.command = pkgs.writeShellScript "late" ''
            echo "NXINIT-SHUTDOWN-1-late" > /dev/console
          '';
        };

        later = {
          requires = [ "shutdown" ];
          type.oneshot.command = pkgs.writeShellScript "later" ''
            echo "NXINIT-SHUTDOWN-2-later" > /dev/console
          '';
        };
      };
    };

  testScript = ''
    machine.start()

    # there is no control socket to ask - nxinit has none and neither does the shell that
    # supervises for it - so readiness is read from the latch directory the jobs write, which
    # is what `initctl status` reads too.
    def ready(unit):
        return f"test -e /run/providers-services/{unit}.ready"

    with subtest("the machine boots at all, which is the exec under test"):
        # rc.init is a shell script and this backend execs by descriptor, so reaching any
        # latch means /dev/fd existed at the moment nxinit exec'd it. A failure here is the
        # `pre` op not having run, and looks like:
        #   bash: /dev/fd/3: No such file or directory
        machine.wait_until_succeeds(ready("start"), timeout=120)

    with subtest("the trunk came up in order"):
        for level in ["start", "sysinit", "basic", "multi-user", "running"]:
            machine.wait_until_succeeds(ready(level))

    with subtest("a oneshot ran and latched"):
        machine.wait_until_succeeds(ready("early"))
        machine.succeed("test -e /run/svc-test/early.ran")

    with subtest("services are supervised and their dependents released"):
        for svc in ["alpha", "beta", "gamma"]:
            machine.wait_until_succeeds(ready(svc))
            machine.succeed(f"test -e /run/svc-test/{svc}.running")
            machine.succeed(f"test -e /run/providers-services/{svc}.pid")

    with subtest("a killed service is respawned"):
        pid = machine.succeed("cat /run/providers-services/alpha.pid").strip()
        machine.succeed(f"kill -KILL -- -{pid}")
        machine.wait_until_succeeds(
            f"test \"$(cat /run/providers-services/alpha.pid)\" != {pid}"
        )

    with subtest("initctl reports state without a control socket"):
        machine.succeed("initctl list > /tmp/units; grep -q alpha /tmp/units")
        machine.wait_until_succeeds("initctl status alpha > /tmp/st; grep -q running /tmp/st")

    with subtest("shutdown runs the shutdown side, in trunk order"):
        # `initctl poweroff` rather than `machine.shutdown()`, which asks qemu for an ACPI
        # powerdown. Nothing here listens for that: nxinit blocks CHLD, USR1 and USR2 and
        # answers nothing else, so an ACPI event reaches no one and the machine sits there
        # until the driver times out. The contract's own command is what asks this backend to
        # stop, and it resolves to `kill -s USR2 1`.
        #
        # Backgrounded and detached because it does not return - the machine is going down
        # under the shell running it.
        machine.execute("(initctl poweroff &) >/dev/null 2>&1", check_return=False)

        # the whole of what distinguishes this backend from upstream nxinit: USR2 spawns
        # rcshutdown instead of calling reboot(2), so these units have somewhere to run.
        machine.wait_for_console_text("NXINIT-SHUTDOWN-1-late")
        machine.wait_for_console_text("NXINIT-SHUTDOWN-2-later")

        # let the driver notice the machine is gone before it runs cleanup on a dead shell
        machine.wait_for_shutdown()
  '';
}
