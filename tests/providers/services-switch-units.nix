# what a switch does to running services, between two separate configurations, on runit
#
# The question this answers is not "did the switch work" but "did it move only what changed".
# A switch which restarts everything looks identical from the outside to one which restarts
# nothing, until you ask what happened to a service that was meant to be left alone - so the
# assertion that matters here is the one about `keeper` keeping its pid.
#
# runit because it has no notion of generations at all: everything visible here is the
# contract's engine doing the reconciling, not a supervisor being clever on its own. The second
# generation is a whole configuration named by store path, not a specialisation.
let
  pkgs = import (import ../../lon.nix).nixpkgs { };
  inherit (pkgs) lib;

  testLib = import ../lib {
    inherit pkgs;
    inherit (pkgs) lib;
  };

  # a long-running process identifiable by name, so `pgrep -f` can find it and its pid can be
  # compared across the switch
  daemon =
    name:
    # not `exec -a`: coreutils here is a multi-call binary which dispatches on argv[0], so
    # renaming the process makes it answer "unknown program" instead of sleeping. Backgrounding
    # and waiting keeps the script.s own path - which carries the name - as this process.s
    # command line, which is what pgrep -f then matches.
    pkgs.writeShellScript "finix-daemon-${name}" ''
      ${lib.getExe' pkgs.coreutils "sleep"} infinity &
      wait
    '';

  base = {
    services.mdevd.enable = true;
    services.getty.enable = true;

    providers.services.backend = "runit";

    providers.services.units = {
      # in both generations, unchanged: nothing about it differs, so nothing should happen to it
      keeper = {
        type.service.command = daemon "keeper";
        requires = [ "sysinit" ];
      };
    };
  };

  next = {
    imports = [ base ];

    providers.services.units = {
      # gone in the second generation
      goner.enable = lib.mkForce false;

      # and one which only exists there
      newcomer = {
        type.service.command = daemon "newcomer";
        requires = [ "sysinit" ];
      };
    };
  };

  nextSystem = (testLib.evalNode "machine" next).config.system.topLevel;
in
{
  name = "providers.services-switch-units";

  nodes.machine =
    { ... }:
    {
      imports = [ base ];

      providers.services.units.goner = {
        type.service.command = daemon "goner";
        requires = [ "sysinit" ];
      };
    };

  testScript = ''
    def pid_of(name):
        code, out = machine.execute(f"pgrep -f '[f]inix-daemon-{name}'")
        return out.strip() if code == 0 else None

    machine.start()
    machine.wait_until_succeeds("test -e /run/providers-services/running.ready", timeout=240)

    with subtest("the first generation's services are up"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-keeper'", timeout=60)
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-goner'", timeout=60)

        keeper_before = pid_of("keeper")
        print(f"keeper before: {keeper_before}")
        assert pid_of("newcomer") is None, "newcomer is running before the switch"

    with subtest("switching into a configuration which drops one and adds another"):
        out = machine.succeed("${nextSystem}/bin/switch-to-configuration test 2>&1")
        print(out)

        # what the engine says it did, which should name both and neither of the others
        assert "goner" in out, f"the engine did not mention goner: {out}"
        assert "newcomer" in out, f"the engine did not mention newcomer: {out}"

    with subtest("the one that went away is down"):
        machine.wait_until_fails("pgrep -f '[f]inix-daemon-goner'", timeout=60)

    with subtest("the one that arrived is up"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-newcomer'", timeout=60)

    with subtest("and the one that did not change was left alone"):
        # the whole point: same process, not a restarted one. A switch which cannot tell the
        # difference would have taken this down and brought it back with a new pid.
        keeper_after = pid_of("keeper")
        print(f"keeper after: {keeper_after}")

        assert keeper_after is not None, "keeper is not running after the switch"
        assert keeper_after == keeper_before, (
            f"keeper was restarted: {keeper_before} -> {keeper_after}"
        )

    with subtest("the trunk is intact"):
        machine.succeed("test -e /run/providers-services/running.ready")
        machine.succeed("test -e /run/providers-services/multi-user.ready")

    machine.shutdown()
  '';
}
