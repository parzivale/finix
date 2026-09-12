# what a switch does to per-user services, on runit
#
# The system side is covered by services-switch-units. This asks the same questions of a user's
# own tree under the first rule - no separate user supervisor, so the units are flattened into
# the system graph with scoped names and the engine sees them as it sees any others.
#
# Which is the thing worth checking: a user unit is `agent--alice` to the engine, and its edges
# to other units of the same user are rewritten to match. If that scoping were not stable
# across generations, a switch would stop and start the wrong things, or fail to find them.
let
  pkgs = import (import ../../lon.nix).nixpkgs { };
  inherit (pkgs) lib;

  testLib = import ../lib {
    inherit pkgs;
    inherit (pkgs) lib;
  };

  # identifiable by name in the process table, and not `exec -a`: coreutils here is a
  # multi-call binary which dispatches on argv[0] and would refuse the renamed program
  daemon =
    name:
    pkgs.writeShellScript "finix-daemon-${name}" ''
      ${lib.getExe' pkgs.coreutils "sleep"} infinity &
      wait
    '';

  base = {
    services.mdevd.enable = true;
    services.getty.enable = true;

    providers.services.backend = "runit";

    users.users.alice = {
      uid = 3001;
      group = "users";
      home = "/home/alice";
    };

    providers.services.units.keeper = {
      type.service.command = daemon "keeper";
      requires = [ "sysinit" ];
    };

    providers.services.users.alice.units = {
      # alice's own, in both generations and unchanged
      agent = {
        type.service.command = daemon "agent";
        requires = [ "sysinit" ];
      };
    };
  };

  next = {
    imports = [ base ];

    providers.services.users.alice.units = {
      # gone in the second generation
      helper.enable = lib.mkForce false;

      # and one which only exists there, depending on alice's own agent - an edge the
      # flattening has to scope to `agent--alice` rather than leave pointing at a system unit
      courier = {
        type.service.command = daemon "courier";
        requires = [ "agent" ];
      };
    };
  };

  nextSystem = (testLib.evalNode "machine" next).config.system.topLevel;
in
{
  name = "providers.services-switch-users";

  nodes.machine =
    { ... }:
    {
      imports = [ base ];

      providers.services.users.alice.units.helper = {
        type.service.command = daemon "helper";
        requires = [ "agent" ];
      };
    };

  testScript = ''
    def pid_of(name):
        code, out = machine.execute(f"pgrep -f '[f]inix-daemon-{name}'")
        return out.strip() if code == 0 else None

    machine.start()
    machine.wait_until_succeeds("test -e /run/providers-services/running.ready", timeout=240)

    with subtest("alice's services are up, and owned by her"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-agent'", timeout=90)
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-helper'", timeout=90)

        # the engine knows them by their scoped names
        machine.succeed("test -e /run/providers-services/agent--alice.ready")
        machine.succeed("test -e /run/providers-services/helper--alice.ready")

        # and they run as alice, not as root
        owner = machine.succeed(
            "ps -o user= -p $(pgrep -f '[f]inix-daemon-agent')"
        ).strip()
        print(f"agent runs as: {owner}")
        assert owner == "alice", f"agent runs as {owner}"

        agent_before = pid_of("agent")
        print(f"agent before: {agent_before}")

    with subtest("switching into a configuration which changes alice's tree"):
        out = machine.succeed("${nextSystem}/bin/switch-to-configuration test 2>&1")
        print(out)

        # named by their scoped names, which is what the engine reconciles on
        assert "helper--alice" in out, f"the engine did not mention helper--alice: {out}"
        assert "courier--alice" in out, f"the engine did not mention courier--alice: {out}"

    with subtest("the user unit that went away is down"):
        machine.wait_until_fails("pgrep -f '[f]inix-daemon-helper'", timeout=90)
        machine.fail("test -e /run/providers-services/helper--alice.ready")

    with subtest("the user unit that arrived is up, as alice"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-courier'", timeout=90)

        owner = machine.succeed(
            "ps -o user= -p $(pgrep -f '[f]inix-daemon-courier')"
        ).strip()
        assert owner == "alice", f"courier runs as {owner}"

    with subtest("alice's unchanged unit was left alone"):
        agent_after = pid_of("agent")
        print(f"agent after: {agent_after}")

        assert agent_after is not None, "agent is not running after the switch"
        assert agent_after == agent_before, (
            f"agent was restarted: {agent_before} -> {agent_after}"
        )

    with subtest("and so was the system unit"):
        machine.succeed("pgrep -f '[f]inix-daemon-keeper'")
        machine.succeed("test -e /run/providers-services/running.ready")
  '';
}
