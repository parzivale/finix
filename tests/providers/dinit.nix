# the providers.services contract, driven on dinit as PID 1
#
# the finit backend is proven in a VM; this is the same contract on a second init system,
# to find out whether the parts dinit expresses natively actually behave as documented:
#
#   1. `depends-ms` - a milestone dependency, which the manual says the dependant survives
#      the dependency stopping. that is the contract's start-only edge, and on finit it has
#      to be faked with a companion latch task. does it hold here?
#
#   2. the shutdown side. dinit has no runlevels, so the latch cannot be a unit which simply
#      does not exist while the system runs. instead every post-latch unit starts as a no-op
#      and does its work in `stop-command`, with the chain wired backwards so that dinit's
#      reverse-order teardown replays it forwards. does the order come out right?
{
  name = "providers.services-dinit";

  nodes.machine =
    { pkgs, ... }:
    let
      daemon =
        name:
        pkgs.writeShellScript "${name}-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          mkdir -p /run/svc-test
          touch /run/svc-test/${name}.running
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
    in
    {
      # so the test script can call dinitctl
      environment.systemPackages = [ pkgs.dinit ];
      services.mdevd.enable = true;

      # one choice, and it is the whole of the configuration's opinion about init: dinit
      # supervises the units and dinit is what the kernel starts.
      providers.services.backend = "dinit";
      providers.services.trunk.enable = true;

      # `boot` is dinit's own root service, so the trunk's first level cannot use that name
      # here - both would be written to /etc/dinit.d/boot.
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
        early = {
          type.oneshot.command = pkgs.writeShellScript "early" ''
            export PATH=${pkgs.coreutils}/bin:$PATH
            mkdir -p /run/svc-test
            touch /run/svc-test/early.ran
          '';
          requires = [ "start" ];
        };

        alpha = {
          type.service.command = daemon "alpha";
          requires = [ "sysinit" ];
        };

        # the start-only edge under test: alpha is a milestone dependency, so stopping alpha
        # must leave beta running
        beta = {
          type.service.command = daemon "beta";
          requires = [ "alpha" ];
        };

        gamma = {
          type.service.command = daemon "gamma";
          requires = [ "basic" ];
        };

        # shutdown side, at two different trunk positions so their order is unambiguous
        late = {
          requires = [ "stopped" ];
          type.oneshot.command = pkgs.writeShellScript "late" ''
            echo "DINIT-SHUTDOWN-1-late" > /dev/console
          '';
        };

        later = {
          requires = [ "shutdown" ];
          type.oneshot.command = pkgs.writeShellScript "later" ''
            echo "DINIT-SHUTDOWN-2-later" > /dev/console
          '';
        };
      };
    };

  testScript = ''
    def state(svc):
        return machine.succeed(f"dinitctl status {svc}").strip()

    machine.start()

    machine.wait_for_console_text("entering runlevel 2")
    machine.wait_until_succeeds("dinitctl status boot | grep -q STARTED", timeout=120)

    with subtest("trunk levels came up as native internal services"):
        for level in ["start", "sysinit", "basic", "multi-user", "running"]:
            machine.wait_until_succeeds(
                f"dinitctl status {level} | grep -q 'State: STARTED'"
            )

    with subtest("units attached to the trunk started"):
        machine.succeed("test -f /run/svc-test/early.ran")
        for svc in ["alpha", "beta", "gamma"]:
            machine.wait_until_succeeds(f"dinitctl status {svc} | grep -q 'State: STARTED'")
            machine.succeed(f"test -f /run/svc-test/{svc}.running")

    with subtest("the shutdown side is up but has not done its work"):
        # post-latch units start as no-ops; their real work is in stop-command
        for svc in ["stopped", "late", "later", "shutdown"]:
            machine.succeed(f"dinitctl status {svc} | grep -q 'State: STARTED'")

    # question 1: is depends-ms genuinely a start-only edge?

    with subtest("QUESTION 1: stopping a milestone dependency leaves its dependant running"):
        machine.succeed("dinitctl stop alpha")
        machine.sleep(2)
        print("alpha: " + state("alpha"))
        print("beta:  " + state("beta"))
        machine.succeed("dinitctl status beta | grep -q 'State: STARTED'")

    machine.shutdown()
  '';
}
