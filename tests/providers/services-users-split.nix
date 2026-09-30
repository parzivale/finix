# per-user service graphs, started by a session
#
# `providers.services.user.backend` names the implementation which supervises a user's tree, and
# an instance of it is started by that user's session rather than at boot. finit is PID 1 and
# dinit is alice's supervisor here, which is the combination worth testing: the session runs a
# command nothing on the system side has to understand, so nothing about finit knows what a dinit
# is.
#
# What it costs is that the two supervisors cannot observe each other, so a user unit may only
# depend on other units of the same user. The contract asserts against a crossing edge rather than
# letting it quietly stop meaning what it said. What the whole tree waits for is whatever started
# the session.
#
# There used to be a second rule, where a user's units were emitted into the system supervisor and
# owned by that user - ordinary system units wearing a name. It is gone, and so is the test for it:
# a supervisor already running when a session begins cannot inherit anything from it, which is the
# whole reason to have one per session.
{
  name = "providers.services-users-split";

  nodes.machine =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      whoami =
        name:
        pkgs.writeShellScript name ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          mkdir -p /run/svc-test
          id -un > /run/svc-test/${name}.user
          exec sleep infinity
        '';
    in
    {
      imports = [ ../lib/contract-base.nix ];

      environment.systemPackages = [ pkgs.dinit ];

      providers.services.user.backend = "dinit";

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };

      providers.services.units.shared = {
        type.oneshot.command = pkgs.writeShellScript "shared" ''
          ${pkgs.coreutils}/bin/mkdir -p /run/svc-test
          ${pkgs.coreutils}/bin/chmod 1777 /run/svc-test
          ${pkgs.coreutils}/bin/touch /run/svc-test/shared.ran
        '';
        requires = [ "sysinit" ];
      };

      providers.services.users.alice.units = {
        agent = {
          type.service.command = whoami "alice-agent";

          # `requires` defaults to the first trunk level, which is a system unit - so a user
          # unit under this rule has to opt out of it explicitly. see the note in the test
          # header: the default is scope-blind and should not be.
          requires = [ ];
        };

        # only edges within alice's own tree are available here - `shared` would be refused
        helper = {
          type.service.command = whoami "alice-helper";
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

      with subtest("her tree was written out for her own supervisor"):
          for unit in ["agent", "helper", "boot", "start"]:
              machine.succeed(f"test -e /etc/dinit-user/alice/{unit}")

          # and not into the system supervisor's own configuration
          machine.fail("test -e /etc/finit.d/agent--alice.conf")
          machine.fail("test -e /etc/finit.d/agent.conf")

      with subtest("the socket directory is hers before any session starts"):
          # the one part of this which needs root, and so the one part left at boot
          machine.wait_until_succeeds("test -d /run/user-services/alice", timeout=90)
          assert machine.succeed("stat -c %U /run/user-services/alice").strip() == "alice"

      with subtest("nothing of hers is running yet"):
          # which is the point of the rule: her units belong to a session, and there is not one
          machine.fail("dinitctl -p /run/user-services/alice/dinitctl status agent")
          machine.fail("test -f /run/svc-test/alice-agent.user")

      with subtest("a session starts her supervisor"):
          # what greetd does: run the launcher as the user, with the session as its payload. No
          # `--session-env`, there being no compositor here to wait for.
          machine.succeed(
              "setpriv --reuid=3001 --regid=100 --clear-groups "
              "${nodes.machine.config.providers.services.user.sessionLauncher} --user alice -- sleep infinity >/dev/null 2>&1 &"
          )
          machine.wait_until_succeeds(
              "dinitctl -p /run/user-services/alice/dinitctl status agent | grep -q STARTED",
              timeout=90,
          )

      with subtest("her units are running, owned by her"):
          machine.wait_until_succeeds("test -f /run/svc-test/alice-agent.user", timeout=90)
          machine.wait_until_succeeds("test -f /run/svc-test/alice-helper.user", timeout=90)
          assert machine.succeed("cat /run/svc-test/alice-agent.user").strip() == "alice"
          assert machine.succeed("cat /run/svc-test/alice-helper.user").strip() == "alice"

      with subtest("ending the session takes the whole tree with it"):
          # the payload exiting is what a logout is, and the launcher stops the supervisor behind
          # it. This is what the boot-started arrangement could not do at all: nothing told it a
          # session had ended.
          machine.succeed("pkill -u alice -x sleep")
          machine.wait_until_fails(
              "dinitctl -p /run/user-services/alice/dinitctl status agent",
            timeout=timedelta(seconds=30),
          )

      machine.shutdown()
    '';
}
