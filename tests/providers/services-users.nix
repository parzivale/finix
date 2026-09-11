# per-user service graphs, supervised by the system supervisor
#
# this is the first of the two rules for user units. No separate user supervisor is declared,
# so a user's units are emitted into the system one, owned by that user. They are then ordinary
# units in every respect, which is what lets them require system units freely - there is only
# one supervisor, so an edge leaving a user's tree is not special at all.
#
# that freedom is exactly what disappears under the second rule, where the system supervisor
# runs a separate user supervisor and the two cannot observe each other. The contract asserts
# against such an edge in that case rather than letting it silently stop meaning what it said.
{
  name = "providers.services-users";

  nodes.machine =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      # records the user it is actually running as, so the test can tell whether ownership
      # survived the flattening
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

      environment.etc."services-switch".source = config.system.build.servicesSwitch;

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };
      users.users.bob = {
        group = "users";
        home = "/home/bob";
        uid = 3002;
      };

      # a system unit for the users' trees to hang off, to show a cross-scope edge working
      providers.services.units.shared = {
        type.oneshot.command = pkgs.writeShellScript "shared" ''
          ${pkgs.coreutils}/bin/mkdir -p /run/svc-test
          ${pkgs.coreutils}/bin/chmod 1777 /run/svc-test
          ${pkgs.coreutils}/bin/touch /run/svc-test/shared.ran
        '';
        requires = [ "sysinit" ];
      };

      providers.services.users.alice.units = {
        # depends on a system unit: legal under this rule, and the point of it
        agent = {
          type.service.command = whoami "alice-agent";
          requires = [ "shared" ];
        };

        # and on another of alice's own units, which is scoped with her when emitted
        helper = {
          type.service.command = whoami "alice-helper";
          requires = [ "agent" ];
        };
      };

      providers.services.users.bob.units.agent = {
        type.service.command = whoami "bob-agent";
        requires = [ "shared" ];
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

    with subtest("a user's units are emitted scoped to that user"):
        for unit in ["agent--alice", "helper--alice", "agent--bob"]:
            machine.wait_until_succeeds(f"test -e /etc/finit.d/{unit}.conf", timeout=60)

    with subtest("each runs as its owner"):
        machine.wait_until_succeeds("test -f /run/svc-test/alice-agent.user", timeout=60)
        machine.wait_until_succeeds("test -f /run/svc-test/bob-agent.user", timeout=60)
        machine.wait_until_succeeds("test -f /run/svc-test/alice-helper.user", timeout=60)
        assert machine.succeed("cat /run/svc-test/alice-agent.user").strip() == "alice"
        assert machine.succeed("cat /run/svc-test/alice-helper.user").strip() == "alice"
        assert machine.succeed("cat /run/svc-test/bob-agent.user").strip() == "bob"

    with subtest("an edge leaving a user's tree reaches the system unit"):
        # alice's agent requires `shared`, a system unit, and only started because it ran
        machine.succeed("test -f /run/svc-test/shared.ran")
        assert status("agent--alice") == "running"

    with subtest("an edge inside a user's tree was scoped with them"):
        # helper requires `agent`, which means alice's agent and not bob's
        conf = machine.succeed("cat /etc/finit.d/helper--alice.conf")
        assert "agent--alice-started" in conf, conf
        assert "agent--bob" not in conf, conf

    with subtest("one user's units can be stopped without touching another's"):
        machine.succeed("initctl stop agent--alice")
        machine.succeed("initctl stop helper--alice")
        machine.sleep(2)

        assert status("agent--alice") == "stopped", status("agent--alice")
        assert status("agent--bob") == "running", status("agent--bob")

    with subtest("and the engine puts them back"):
        out = machine.succeed("/etc/services-switch 2>&1")
        print(out)
        machine.wait_until_succeeds(
            "initctl -j status agent--alice | grep -q running", timeout=60
        )

    machine.shutdown()
  '';
}
