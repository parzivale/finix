# a service which opens a terminal actually owns it
#
# `providers.ttys` lowers every device to an ordinary supervised process - `agetty`, started the
# same way any other daemon is - on the understanding that `agetty` is entirely capable of
# claiming its own controlling terminal once it is a session leader with none yet. Whether it
# gets to be one is the supervisor's problem, not the contract's, and it turned out three of the
# four solve it without being asked: finit and dinit call `setsid()` unconditionally before
# exec, and s6-supervise passes `CSPAWN_FLAGS_SETSID` to every service it spawns. runit's
# `runsv` calls neither - it forks and execs the run script directly - so without something in
# the run script itself doing it, every service shares runsvdir's own session, `agetty` is never
# a session leader, and `ioctl(TIOCSCTTY)` fails with EPERM. `ps` still shows the process
# running; nothing crashes or restarts. The only trace is a warning agetty prints to a console
# nobody is necessarily watching.
#
# That is a silent failure, and not only a cosmetic one: a process which does not own its
# controlling terminal is also a process sharing a session (and, without `runsvdir -P`, a
# process group) with services that have nothing to do with it - the isolation a session
# boundary is supposed to provide simply is not there. So this is asserted directly, on every
# backend, rather than trusted to hold because it held during manual testing.
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
  name = "providers.ctty-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];
    };

  testScript = ''
    import datetime

    ${coreLib.prelude}

    machine.start()
    wait_booted()

    # the bracket keeps pgrep's own command line from matching itself - `bash -c "pgrep -f
    # 'agetty.*tty1'"` contains the literal text of the pattern, which the pattern then matches
    # against its own invocation, same pitfall `coreLib.pid_of` works around for the same reason.
    #
    # Anchored at the start, because a supervisor which execs nothing itself still carries the
    # command line of what it supervises: openrc's `supervise-daemon tty-tty1 --start
    # .../agetty -- ... tty1` matches an unanchored pattern just as well as the agetty does,
    # and two pids is not something the rest of this can do anything sensible with. The process
    # being asked about is the one which *is* agetty, so the match is on argv[0].
    def agetty_pid():
        return machine.succeed("pgrep -f '^[^ ]*[a]getty.*tty1'").strip()

    def ctty_state(pid):
        # tty, sid and pgid in one call, so the three are read from a single consistent
        # snapshot of the process rather than three that could each see a different one
        out = machine.succeed(f"ps -o tty=,sid=,pgid= -p {pid}").split()
        return {"tty": out[0], "sid": out[1], "pgid": out[2]}

    with subtest("the tty1 login prompt owns its controlling terminal"):
        pid = agetty_pid()
        state = ctty_state(pid)
        assert state["tty"] == "tty1", (
            f"agetty {pid} has no controlling terminal (tty={state['tty']!r}) - "
            "it never became a session leader before ioctl(TIOCSCTTY)"
        )
        assert state["sid"] == pid, (
            f"agetty {pid} is not its own session leader (sid={state['sid']}) - "
            "it is sharing a session with whatever started it"
        )
        assert state["pgid"] == pid, (
            f"agetty {pid} is not its own process group leader (pgid={state['pgid']})"
        )

    with subtest("a respawned instance acquires it again, not just the first one"):
        first_pid = agetty_pid()
        machine.succeed(f"kill -9 {first_pid}")
        machine.wait_until_succeeds(
            f"pgrep -f '^[^ ]*[a]getty.*tty1' | grep -qxv {first_pid}",
            timeout=datetime.timedelta(seconds=30),
        )
        second_pid = agetty_pid()
        assert second_pid != first_pid, "the process was not actually replaced"
        state = ctty_state(second_pid)
        assert state["tty"] == "tty1" and state["sid"] == second_pid, (
            f"the respawned agetty {second_pid} did not acquire its controlling "
            f"terminal (tty={state['tty']!r}, sid={state['sid']})"
        )

    machine.shutdown()
  '';
}
