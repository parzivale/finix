# a session whose supervisor fails, and says so
#
# The launcher reports a supervisor that exits non-zero while the session is still running. That
# report is not decoration: it was the systemd module's own line, printed by a shell wrapper, and
# it was the only evidence there was when that backend's user manager could not start - once
# because pid 1 had not taken its bus name, once because polkit had never heard of the action.
# Both failures were a session with no tree and nothing anywhere saying why. The wrapper is gone
# and the report belongs to every implementation now, so it is worth one test of its own.
#
# The supervisor here is `false`, forced over whatever the backend would have supplied. Which is
# the only honest way to test this: a real backend failing needs a real thing to be broken, and
# what is under test is the launcher's reaction rather than any particular breakage.
#
# Two claims, and the second is the one a reader would not assume. A failed tree is reported, and
# a failed tree does not end the session: the payload is the point of a login, and a user whose
# services did not start should still get their compositor.
{
  name = "providers.session-launch";

  nodes.machine =
    {
      pkgs,
      lib,
      ...
    }:
    {
      imports = [ ../lib/contract-base.nix ];

      # dinit, so that an implementation has claimed the user scope and `supervisor` exists to be
      # overridden. Nothing of dinit's actually runs here.
      dinit.userSupervisor.enable = true;

      environment.systemPackages = [ pkgs.procps ];

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };

      providers.services.user.manager.supervisor.command = lib.mkForce (_user: [
        "${pkgs.coreutils}/bin/false"
      ]);

      providers.services.users.alice.units.agent = {
        type.service.command = "${pkgs.coreutils}/bin/true";
        requires = [ ];
      };
    };

  testScript =
    { nodes, ... }:
    ''
      from datetime import timedelta

      machine.start()
      machine.wait_for_console_text("entering runlevel 2")

      machine.wait_until_succeeds("test -d /run/user-services/alice", timeout=90)

      with subtest("a supervisor which fails is reported"):
          machine.succeed(
              "setpriv --reuid=3001 --regid=100 --clear-groups "
              "${nodes.machine.config.providers.services.user.sessionLauncher} "
              "--user alice -- sleep infinity >/run/session-launch.log 2>&1 &"
          )

          machine.wait_until_succeeds(
              "grep -q 'the supervisor for alice exited 1' /run/session-launch.log",
              timeout=90,
          )

      with subtest("and the session carries on without a tree"):
          # the payload is what a login is for. A tree which did not start is a tree which did not
          # start; it is not a reason to log the user out.
          machine.succeed("pgrep -u alice -x sleep")
          machine.succeed("pgrep -u alice -f 'session-launch --user alice'")

          # matched on the argv rather than the name: `sessionLauncher` is a symlink called
          # `session-launch`, so nothing in a running process says `finix-session-launch` - which
          # a first attempt at this asserted, and which would have made the teardown subtest below
          # pass against a launcher that never exited.

          # said once, not once per poll: `await_payload` latches the report.
          count = machine.succeed(
              "grep -c 'the supervisor for alice exited' /run/session-launch.log"
          ).strip()
          assert count == "1", count

      with subtest("ending the session does not hang on a supervisor already gone"):
          # the launcher still runs its teardown, which finds the child reaped and returns rather
          # than signalling a pid that is not there and waiting out the grace period.
          machine.succeed("pkill -u alice -x -f 'sleep infinity'")
          machine.wait_until_fails(
              "pgrep -u alice -f 'session-launch --user alice'", timeout=timedelta(seconds=30)
          )

          # and it did not take the five seconds a kill-then-wait would have: that path ends in a
          # line of its own, which is not here.
          machine.fail("grep -q 'did not stop' /run/session-launch.log")

      machine.shutdown()
    '';
}
