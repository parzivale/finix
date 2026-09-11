# the switch engine, driven against dinit
#
# on finit the engine's arithmetic never really runs: finit reconciles from its own
# configuration, so its `list` reports nothing, every unit reads as new, and a single reload
# does the work. dinit does not self-reconcile - which is why this branch carries a bespoke
# python reconciler - so it gives the engine a real `list`, and the diff has to be correct.
#
# the engine is a standalone program, so this drives it directly rather than through
# switch-to-configuration, and creates the difference by hand:
#
#   1. with the system as built, `list` should match the incoming tree exactly - nothing to do
#   2. stop a unit behind the engine's back; it should notice and start it again
#   3. and it should leave everything else alone while doing so
{
  name = "providers.services-dinit-switch";

  nodes.machine =
    { pkgs, config, ... }:
    let
      daemon =
        name:
        pkgs.writeShellScript "${name}-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          mkdir -p /run/svc-test
          echo up >> /run/svc-test/${name}.starts
          exec sleep infinity
        '';
    in
    {
      # finit is PID 1 here, so it wants a terminal defined
      finit.ttys.tty1 = {
        description = "getty on /dev/tty1";
        nowait = true;
      };

      # dinit runs supervised by finit rather than as PID 1. taking the other branch's
      # `finit.enable` would also take its init-selection logic in system/activation, which is
      # the same decision providers.services.backend already makes.
      # so the test script can call dinitctl
      environment.systemPackages = [ pkgs.dinit ];

      finit.services.dinit = {
        description = "dinit service manager";
        runlevels = "S12345789";
        path = [ pkgs.dinit ];
        log = true;
        command = "${pkgs.dinit}/bin/dinit -p /run/dinitctl -d /etc/dinit.d boot";
      };

      # the engine is a standalone program; expose it at a fixed path so the test can run it
      environment.etc."services-switch".source = config.system.build.servicesSwitch;
      services.mdevd.enable = true;

      providers.services.backend = "dinit";
      providers.services.trunk.enable = true;
      providers.services.trunk.levels = [
        "start"
        "sysinit"
        "basic"
        "multi-user"
        "running"
        "stopped"
        "shutdown"
      ];

      providers.services.units = {
        keeper = {
          type.service.command = daemon "keeper";
          requires = [ "sysinit" ];
        };

        drifter = {
          type.service.command = daemon "drifter";
          requires = [ "sysinit" ];
        };
      };
    };

  testScript = ''
    def starts(name):
        code, out = machine.execute(f"cat /run/svc-test/{name}.starts")
        return out.strip().splitlines() if code == 0 else []

    machine.start()
    machine.wait_for_console_text("entering runlevel 2")
    machine.wait_until_succeeds("dinitctl status boot | grep -q STARTED", timeout=120)

    engine = "/etc/services-switch"

    with subtest("both units came up"):
        for svc in ["keeper", "drifter"]:
            machine.wait_until_succeeds(f"test -f /run/svc-test/{svc}.starts", timeout=60)
            assert starts(svc) == ["up"], f"{svc}: {starts(svc)}"

    with subtest("list matches the incoming tree, so the engine has nothing to do"):
        out = machine.succeed(f"{engine} 2>&1")
        print(out)
        assert "starting:" not in out, f"engine wanted to start something: {out}"
        assert "stopping:" not in out, f"engine wanted to stop something: {out}"

    with subtest("a unit stopped behind the engine's back is noticed and restarted"):
        machine.succeed("dinitctl stop drifter")
        machine.sleep(2)

        out = machine.succeed(f"{engine} 2>&1")
        print(out)
        assert "drifter" in out, f"engine did not notice drifter: {out}"
        assert "keeper" not in out, f"engine disturbed keeper: {out}"

        machine.wait_until_succeeds(
            "dinitctl status drifter | grep -q 'State: STARTED'", timeout=30
        )
        assert starts("drifter") == ["up", "up"], f"drifter: {starts('drifter')}"

    with subtest("the untouched unit was never restarted"):
        assert starts("keeper") == ["up"], f"keeper: {starts('keeper')}"

    machine.shutdown()
  '';
}
