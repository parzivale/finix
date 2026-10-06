# `initctl` controls the system tree, whichever init is underneath
#
# The tool is generated once in `providers/services/ctl.nix` and shared by every backend - it
# resolves a name, then execs whatever that backend supplied for `ctl.status`, `switch.activate`
# and `switch.deactivate`. So there is no per-backend version of it to test, only one piece of
# glue whose job is to reach the right command, and this asserts that it does.
#
# Written before the tool was ported out of shell, and deliberately: the two bugs its own
# comments record are both argument-handling - a refusal which exited 0 because it happened
# inside `$(...)`, and a `--user` flag recognised in one position and silently ignored in every
# other - and neither had a test. A port with no test before it would only ever have proved that
# the new thing agreed with itself.
#
# Only the system tree is asserted here, because only the system tree is universal: a user tree
# needs an implementation which claims the user namespace, which is dinit's and systemd's alone.
# The cross-tree half of `resolve` is in tests/providers/initctl-trees.nix.
#
# What is deliberately *not* asserted is the state word after a stop. An implementation which
# keeps a record of every unit reports `stopped`; one whose state is derived from files that
# `deactivate` removes reports nothing at all, the unit having ceased to exist as far as it is
# concerned. Both are honest and the contract does not choose, so this asserts the process
# instead, which it does promise.
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
  name = "providers.initctl-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        # the unit this drives. Nothing else requires it, so stopping and starting it says
        # nothing about the rest of the machine - which matters because the driver's own shell
        # is a unit too.
        subject = {
          type.service.command = coreLib.daemon "subject";
          requires = [ "sysinit" ];
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()
    machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-subject'", timeout=60)

    with subtest("list is one table covering every tree"):
        out = machine.succeed("initctl list")

        # the header is the contract's, not an implementation's: `ctl.status` is specified to
        # answer in `running`/`done`/`stopped` precisely so one listing can mix trees without
        # saying the same thing two ways.
        assert out.splitlines()[0].split() == ["TREE", "UNIT", "STATE"], out

        rows = [l.split() for l in out.splitlines()[1:]]
        subject = [r for r in rows if len(r) >= 3 and r[1] == "subject"]
        assert len(subject) == 1, out
        assert subject[0][0] == "system", out
        assert subject[0][2] == "running", out

    with subtest("status answers for one unit, in the contract's vocabulary"):
        assert machine.succeed("initctl status subject").strip() == "running"

    with subtest("an unknown name is refused, and says so with its exit status"):
        # the bug this pins: the refusal was computed in a command substitution, so the `exit`
        # ended the subshell and `initctl` went on to report success. A caller testing the exit
        # status - which is the only thing a script can do - was told the unit existed.
        machine.fail("initctl status no-such-unit")

        _, err = machine.execute("initctl status no-such-unit 2>&1 >/dev/null")
        assert "no-such-unit" in err, err

    with subtest("--system is accepted wherever it appears"):
        # the other bug: the flag was only recognised immediately after the command, so putting
        # it anywhere else was not an error but a silent change of meaning.
        before = machine.succeed("initctl --system status subject").strip()
        after = machine.succeed("initctl status subject --system").strip()
        assert before == after == "running", (before, after)

    # start, stop and restart are deliberately not here: they are not universal. See
    # core/initctl-control.nix, which asserts them over every backend that can express them.
  '';
}
