# `initctl start|stop|restart` acts on the unit it was given
#
# Split out of core/initctl.nix because it is not universal, and the reason is worth writing down
# rather than leaving as a missing row.
#
# `initctl` has no per-unit control operation of its own. It composes `switch.activate` and
# `switch.deactivate`, which are the *reconciliation* primitives - what `switch-to-configuration`
# drives - and for six of the seven backends those happen to take unit names on stdin, so feeding
# them one name does what a person means by "stop this".
#
# finit's do not. Its `switch.activate` and `switch.deactivate` are both `initctl reload`: it
# reconciles declaratively, by re-reading /etc/finit.d and acting on the difference, and never
# sees a name at all. So on finit `initctl stop foo` reloads a configuration in which `foo` is
# still declared, leaves it running, and reports success. Same for start and restart.
#
# That is a real gap and not a property of this test - the shell version of the tool behaved
# identically, which was confirmed by running this against it before the port. Closing it means
# giving the contract a per-unit control operation that finit fills with its own
# `initctl start|stop|restart <unit>`, which it has natively; the other six alias it to the switch
# primitives they already use. Until then this row excludes finit rather than asserting something
# that backend cannot do.
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
  name = "providers.initctl-control-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units.subject = {
        type.service.command = coreLib.daemon "subject";
        requires = [ "sysinit" ];
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()
    machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-subject'", timeout=60)

    with subtest("stop reaches the backend's own deactivate"):
        machine.succeed("initctl stop subject")
        machine.wait_until_fails("pgrep -f '[f]inix-daemon-subject'", timeout=60)

    with subtest("and start reaches its activate"):
        machine.succeed("initctl start subject")
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-subject'", timeout=60)
        assert machine.succeed("initctl status subject").strip() == "running"

    with subtest("restart replaces the process rather than leaving it"):
        was = pid_of("subject")
        assert was is not None

        machine.succeed("initctl restart subject")

        # by pid, not by absence: a restart which did nothing at all would pass a check that only
        # looked for something running afterwards.
        machine.wait_until_succeeds(
            f"pgrep -f '[f]inix-daemon-subject' | grep -qv '^{was}$'", timeout=60
        )
  '';
}
