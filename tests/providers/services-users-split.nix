# per-user service graphs under a separate user supervisor
#
# the second of the two rules. `providers.services.user.backend` names a different
# implementation from the system one, so the system supervisor no longer owns the user's units:
# it runs one user supervisor per user, and that supervisor owns them.
#
# finit is PID 1 and dinit supervises each user here, which is the combination worth testing -
# the system side runs a command it does not have to understand, so nothing about finit knows
# what a dinit is. systemd is the awkward case rather than this one: `systemd --user` expects
# PID 1 systemd to have prepared its cgroup and bus, so it can serve both scopes only as a
# matched pair.
#
# what this costs is the freedom rule 1 has. The two supervisors cannot observe each other, so
# a user unit may only depend on other units of the same user; what the whole tree waits for is
# whatever the unit running that user's supervisor waits for. The contract asserts against a
# crossing edge rather than letting it quietly stop meaning what it said.
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

  testScript = ''
    import json

    def status(name):
        out = machine.execute(f"initctl -j status {name}")[1]
        try:
            return json.loads(out)["status"]
        except Exception:
            return "absent"

    machine.start()
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("the system supervisor runs one user supervisor"):
        machine.wait_until_succeeds(
            "initctl -j status user-services--alice | grep -q running", timeout=90
        )

    with subtest("alice's tree was written out for her own supervisor"):
        for unit in ["agent", "helper", "boot"]:
            machine.succeed(f"test -e /etc/dinit-user/alice/{unit}")

        # and not into the system supervisor's own configuration
        machine.fail("test -e /etc/finit.d/agent--alice.conf")

    with subtest("her units are running, owned by her"):
        machine.wait_until_succeeds("test -f /run/svc-test/alice-agent.user", timeout=90)
        machine.wait_until_succeeds("test -f /run/svc-test/alice-helper.user", timeout=90)
        assert machine.succeed("cat /run/svc-test/alice-agent.user").strip() == "alice"
        assert machine.succeed("cat /run/svc-test/alice-helper.user").strip() == "alice"

    with subtest("her supervisor is reachable, and hers alone"):
        machine.succeed(
            "dinitctl -p /run/user-services/alice/dinitctl status agent | grep -q STARTED"
        )

    with subtest("stopping her supervisor takes the whole tree with it"):
        # this is what makes logout tractable under this rule: one unit, not a subtree
        machine.succeed("initctl stop user-services--alice")
        machine.sleep(3)
        machine.fail("dinitctl -p /run/user-services/alice/dinitctl status agent")

    machine.shutdown()
  '';
}
