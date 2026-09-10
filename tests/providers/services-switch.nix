# switching a running system from one service graph to another
#
# every other test in this directory checks what a machine looks like once it has booted. this
# one checks what happens when the graph changes underneath a machine that is already up, which
# is the case that actually runs on every rebuild rather than once per boot.
#
# the second generation is a specialisation, so both are built from one configuration and the
# running system can switch to the other by path. between them, four things change and one does
# not, which is what the assertions are about:
#
#   keeper    unchanged           - must not be disturbed
#   goner     removed             - must be stopped
#   changer   command changed     - must be restarted, and pick up the new command
#   newcomer  added               - must be started
#   dependant requires changer    - must NOT be restarted, because dependencies gate starting
#                                   only, so a dependency changing is not its business
{
  name = "providers.services-switch";

  nodes.machine =
    { pkgs, lib, ... }:
    let
      # a daemon which records every start, so a restart is visible as a second line rather
      # than having to be caught in the act
      daemon =
        name: tag:
        pkgs.writeShellScript "${name}-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          mkdir -p /run/svc-test
          echo "${tag}" >> /run/svc-test/${name}.starts
          exec sleep infinity
        '';
    in
    {
      services.mdevd.enable = true;
      services.getty.enable = true;

      providers.services.backend = "finit";
      providers.services.trunk.enable = true;

      providers.services.units = {
        keeper = {
          command = daemon "keeper" "gen1";
          requires = [ "sysinit" ];
        };

        goner = {
          command = daemon "goner" "gen1";
          requires = [ "sysinit" ];
        };

        changer = {
          command = daemon "changer" "gen1";
          requires = [ "sysinit" ];
        };

        dependant = {
          command = daemon "dependant" "gen1";
          requires = [ "changer" ];
        };
      };

      specialisation.next = {
        providers.services.units = {
          goner.enable = lib.mkForce false;

          changer = {
            command = lib.mkForce (daemon "changer" "gen2");
          };

          newcomer = {
            command = daemon "newcomer" "gen2";
            requires = [ "sysinit" ];
          };
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

    def starts(name):
        code, out = machine.execute(f"cat /run/svc-test/{name}.starts")
        return out.strip().splitlines() if code == 0 else []

    machine.start()
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("the first generation is up"):
        for svc in ["keeper", "goner", "changer", "dependant"]:
            machine.wait_until_succeeds(f"test -f /run/svc-test/{svc}.starts", timeout=60)
            assert starts(svc) == ["gen1"], f"{svc}: {starts(svc)}"
        assert starts("newcomer") == []

    with subtest("switching to the second generation reports what it moved"):
        out = machine.succeed(
            "/run/current-system/specialisation/next/bin/switch-to-configuration test 2>&1"
        )
        print(out)

    machine.sleep(3)

    with subtest("an added unit is started"):
        assert starts("newcomer") == ["gen2"], f"newcomer: {starts('newcomer')}"

    with subtest("a changed unit is restarted, with the new command"):
        assert starts("changer") == ["gen1", "gen2"], f"changer: {starts('changer')}"

    with subtest("a removed unit is stopped"):
        assert status("goner") in ("stopped", "absent"), f"goner is {status('goner')}"

    with subtest("an unchanged unit is left alone"):
        assert starts("keeper") == ["gen1"], f"keeper was disturbed: {starts('keeper')}"

    with subtest("a dependant of a changed unit is NOT restarted"):
        # the whole point of start-only edges: `dependant` required `changer`, `changer` was
        # replaced, and `dependant` carried on regardless
        assert starts("dependant") == ["gen1"], f"dependant restarted: {starts('dependant')}"

    machine.shutdown()
  '';
}
