# a user's tree supervised by s6-rc, started by her session
#
# The third of these - services-users-split.nix asks it of dinit, runit-user.nix of runit - and
# what each is for is the half the implementation has to arrange itself. s6 arranges the least
# of any of them: the database is compiled into the store and read from there, `s6-rc-init`
# populates the scan directory from it, and s6 speaks readiness natively, so there is no tree to
# copy, nothing to write into /etc, and no latch files.
#
# Which leaves teardown as the thing worth asserting, for the opposite reason to runit's.
# s6-svscan(1) says a TERM makes it "instruct all the s6-supervise processes to stop their
# service and exit; wait for the whole supervision tree to die [...] then exit 0" - so the
# signal the launcher already sends is the right one, and `stopSignal` stays at its default.
# This asserts on the processes rather than on reachability, because that is what distinguishes
# a tree that stopped from a supervisor that merely exited.
{
  name = "providers.s6rc-user";

  nodes.machine =
    {
      pkgs,
      lib,
      ...
    }:
    let
      # records when it is asked to stop, which is what makes the teardown *order* observable.
      # Not `exec sleep`, because a trap does not survive an exec: the shell stays as the
      # service process, waits on the sleep, and appends its name on the way out. s6-supervise
      # signals that shell, so the trap is what runs.
      daemon =
        name: marker:
        pkgs.writeShellScript name ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          mkdir -p /run/svc-test
          id -un > /run/svc-test/${name}.user

          # kills the child before exiting, or the sleep is orphaned and outlives the session -
          # which an `exec sleep` could not have done, the shell having become the sleep.
          trap 'echo ${name} >> /run/svc-test/stop-order; kill "$child" 2>/dev/null; exit 0' TERM

          sleep ${marker} &
          child=$!
          wait "$child"
        '';
    in
    {
      imports = [ ../lib/contract-base.nix ];

      # finit is pid 1 and s6 supervises alice: the session runs a command nothing on the system
      # side has to understand.
      s6-rc.userSupervisor.enable = true;

      environment.systemPackages = [
        pkgs.s6
        pkgs.s6-rc
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

          # `requires` defaults to the first trunk level, which is a system unit - so a user
          # unit has to opt out of it explicitly.
          requires = [ ];
        };

        # an edge inside her own tree, which here is an s6-rc dependency in the compiled
        # database rather than anything synthesised
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
          machine.wait_until_succeeds("test -d /run/user-services/alice", timeout=90)
          assert machine.succeed("stat -c %U /run/user-services/alice").strip() == "alice"

      with subtest("nothing of hers is running yet"):
          machine.fail("test -f /run/svc-test/alice-agent.user")
          machine.fail("pgrep -u alice -x s6-svscan")

      with subtest("a session starts her supervisor"):
          machine.succeed(
              "setpriv --reuid=3001 --regid=100 --clear-groups "
              "${nodes.machine.config.providers.services.user.sessionLauncher} "
              "--user alice -- sleep infinity >/run/session-launch.log 2>&1 &"
          )
          machine.wait_until_succeeds("pgrep -u alice -x s6-svscan", timeout=90)


          # the live directory is s6-rc-init's, run beside s6-svscan once its control fifo
          # appeared - so its existence says the two halves of the supervisor met.
          machine.wait_until_succeeds("test -d /run/user-services/alice/live", timeout=90)

      with subtest("her units are running, owned by her"):
          machine.wait_until_succeeds("test -f /run/svc-test/alice-agent.user", timeout=90)
          machine.wait_until_succeeds("test -f /run/svc-test/alice-helper.user", timeout=90)
          assert machine.succeed("cat /run/svc-test/alice-agent.user").strip() == "alice"
          assert machine.succeed("cat /run/svc-test/alice-helper.user").strip() == "alice"

      with subtest("and are reported the way the contract asks"):
          status = machine.succeed("${nodes.machine.config.providers.services.user.status "alice"}")
          assert "agent\trunning" in status, status
          assert "helper\trunning" in status, status

      with subtest("ending the session takes the whole tree with it"):
          machine.succeed("pkill -u alice -x -f 'sleep infinity'")

          # the supervisor goes, which a TERM would achieve on any of these backends
          machine.wait_until_fails("pgrep -u alice -x s6-svscan", timeout=timedelta(seconds=30))

          # and so does everything under it: no s6-supervise left, and neither daemon.
          machine.wait_until_fails("pgrep -u alice -x s6-supervise", timeout=timedelta(seconds=30))
          machine.wait_until_fails("pgrep -u alice -f 'sleep 123456'", timeout=timedelta(seconds=30))
          machine.wait_until_fails("pgrep -u alice -f 'sleep 234567'", timeout=timedelta(seconds=30))

          # and in dependency order, which is the whole of what `.s6-svscan/SIGTERM` adds over
          # s6-svscan's own TERM. A bare TERM tells every s6-supervise to stop at once; routing
          # it through `s6-rc -bDa change` first brings the set down the way it came up, so the
          # unit that depends on another stops before the one it depends on.
          order = machine.succeed("cat /run/svc-test/stop-order").split()
          assert order == ["alice-helper", "alice-agent"], order

          # and the live directory with it, so the next session starts from nothing rather than
          # finding a database s6-rc-init would refuse to initialise again.
          machine.fail("test -d /run/user-services/alice/live")

      machine.shutdown()
    '';
}
