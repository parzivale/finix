# a user's tree supervised by runit, started by her session
#
# The companion to services-users-split.nix, which asks the same question of dinit. Both are
# worth having because what the two implementations have to do is not the same: dinit is handed a
# directory of descriptions and a socket path and needs nothing else, where runsvdir writes into
# the tree it supervises and so cannot be pointed at the store at all.
#
# The subtest that justifies this file is the last one. Every other implementation of the user
# role is stopped by the signal `sessionLauncher` sends it, and runit is the one where that signal
# means something else: runsvdir(8) says a TERM makes it "exit with 0 immediately", which leaves
# every runsv - and so every one of her daemons - running with nothing supervising them. The
# session ends, the supervisor exits promptly and cleanly, and the tree stays. So this asserts on
# the processes rather than on whether anything can still be reached: `sv status` would keep
# answering from a scan directory full of live runsv, and a test which only asked that would pass
# against exactly the bug.
{
  name = "providers.runit-user";

  nodes.machine =
    {
      pkgs,
      lib,
      ...
    }:
    let
      # a daemon identifiable by its own argv once it has exec'd, because that is what the
      # teardown subtest has to look for. `sleep infinity` would be indistinguishable from the
      # session payload, which is also a sleep.
      daemon =
        name: marker:
        pkgs.writeShellScript name ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          mkdir -p /run/svc-test
          id -un > /run/svc-test/${name}.user
          exec sleep ${marker}
        '';
    in
    {
      imports = [ ../lib/contract-base.nix ];

      # finit is pid 1 and runit supervises alice, which is the combination worth testing: the
      # session runs a command nothing on the system side has to understand.
      runit.userSupervisor.enable = true;

      environment.systemPackages = [
        pkgs.runit
        pkgs.procps
      ];

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };

      providers.services.units.shared = {
        type.oneshot.command = pkgs.writeShellScript "shared" ''
          ${pkgs.coreutils}/bin/mkdir -p /run/svc-test
          ${pkgs.coreutils}/bin/chmod 1777 /run/svc-test
        '';
        requires = [ "sysinit" ];
      };

      providers.services.users.alice.units = {
        agent = {
          type.service.command = daemon "alice-agent" "123456";

          # `requires` defaults to the first trunk level, which is a system unit - so a user unit
          # has to opt out of it explicitly. Same note as in services-users-split.nix.
          requires = [ ];
        };

        # an edge inside her own tree, which on this backend is a latch file under her own
        # directory rather than anything runit knows about
        helper = {
          type.service.command = daemon "alice-helper" "234567";
          requires = [ "agent" ];
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      from datetime import timedelta

      machine.start()
      machine.wait_for_console_text("entering runlevel 2")

      with subtest("her directory is hers before any session starts"):
          # the one part of this which needs root, and so the one part left at boot
          machine.wait_until_succeeds("test -d /run/user-services/alice", timeout=90)
          assert machine.succeed("stat -c %U /run/user-services/alice").strip() == "alice"

      with subtest("nothing of hers is running yet"):
          # her units belong to a session, and there is not one
          machine.fail("test -f /run/svc-test/alice-agent.user")
          machine.fail("pgrep -u alice -x runsvdir")

      with subtest("a session starts her supervisor"):
          # what greetd does: the launcher, as her, with the session as its payload. No
          # --session-env, there being no compositor here to wait for.
          machine.succeed(
              "setpriv --reuid=3001 --regid=100 --clear-groups "
              "${nodes.machine.config.providers.services.user.sessionLauncher} "
              "--user alice -- sleep infinity >/run/session-launch.log 2>&1 &"
          )
          machine.wait_until_succeeds("pgrep -u alice -x runsvdir", timeout=90)

          # the tree is a copy, not the store path: runsv creates supervise/ inside each service
          # directory, which is the whole reason this backend cannot be scanned out of /nix/store
          machine.wait_until_succeeds("test -d /run/user-services/alice/service/agent/supervise", timeout=90)

      with subtest("her units are running, owned by her"):
          machine.wait_until_succeeds("test -f /run/svc-test/alice-agent.user", timeout=90)
          machine.wait_until_succeeds("test -f /run/svc-test/alice-helper.user", timeout=90)
          assert machine.succeed("cat /run/svc-test/alice-agent.user").strip() == "alice"
          assert machine.succeed("cat /run/svc-test/alice-helper.user").strip() == "alice"

      with subtest("and are reported the way the contract asks"):
          # providers.services.user.status, which is what `initctl` reads a user's tree through
          status = machine.succeed("${nodes.machine.config.providers.services.user.status "alice"}")
          assert "agent\trunning" in status, status
          assert "helper\trunning" in status, status

      with subtest("ending the session takes the whole tree with it"):
          # the payload exiting is what a logout is. `-x sleep` matches the payload and not her
          # daemons, which were given argv of their own for exactly this.
          machine.succeed("pkill -u alice -x -f 'sleep infinity'")

          # the supervisor goes, which a TERM would also have achieved
          machine.wait_until_fails("pgrep -u alice -x runsvdir", timeout=timedelta(seconds=30))

          # and so does everything under it, which a TERM would not have. These two are the
          # assertions this file exists for.
          machine.wait_until_fails("pgrep -u alice -x runsv", timeout=timedelta(seconds=30))
          machine.wait_until_fails("pgrep -u alice -f 'sleep 123456'", timeout=timedelta(seconds=30))
          machine.wait_until_fails("pgrep -u alice -f 'sleep 234567'", timeout=timedelta(seconds=30))

      machine.shutdown()
    '';
}
