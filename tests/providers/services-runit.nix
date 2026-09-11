# the providers.services contract driven on runit
#
# runit is not an init. finit is still PID 1 here; runsvdir supervises the contract's units
# underneath it. that alone is worth testing - the other three backends are all PID 1, so this
# is the first evidence the contract abstracts service supervision rather than init.
#
# it is also the first backend whose target cannot do what the contract asks. runit has no
# dependency mechanism at all: every service directory is scanned, a runsv is started for each,
# and they all come up in parallel. ordering is conventionally each service's own problem. so
# the backend synthesises edges out of latch files, and the question this answers is whether
# that actually holds when runit is doing its best to start everything at once.
{
  name = "providers.services-runit";

  nodes.machine =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      services.mdevd.enable = true;
      services.getty.enable = true;

      # so the test script itself can call `sv`
      environment.systemPackages = [ pkgs.runit ];

      providers.services.backend = "runit";
      providers.services.trunk.enable = true;

      providers.services.units = {
        # each records its name the moment it starts, so the file is a record of the order
        # runit actually brought them up in
        first = {
          type.service.command = pkgs.writeShellScript "first" ''
            echo first >> /run/svc-test/order
            exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
          '';
          requires = [ "sysinit" ];
        };

        second = {
          type.service.command = pkgs.writeShellScript "second" ''
            echo second >> /run/svc-test/order
            exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
          '';
          requires = [ "first" ];
        };

        third = {
          type.service.command = pkgs.writeShellScript "third" ''
            echo third >> /run/svc-test/order
            exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
          '';
          requires = [ "second" ];
        };
      };

      # runsv creates `supervise` inside each service directory, so the generated tree has to
      # be somewhere writable rather than read straight out of the store
      finit.tasks.runit-setup = {
        description = "stage the runit service directories";
        runlevels = "S12345789";

        # without this the task re-runs on entering runlevel 2 and its `rm -rf` deletes the
        # tree out from under the runsvdir it just started
        remain = true;
        command = pkgs.writeShellScript "runit-setup" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          mkdir -p /run/svc-test /run/providers-services
          rm -rf /run/service
          cp -rL ${config.providers.services.runit.serviceDir} /run/service
          chmod -R u+w /run/service
        '';
      };

      finit.services.runsvdir = {
        description = "runit service supervisor";
        runlevels = "S12345789";
        conditions = "task/runit-setup/success";

        # runsvdir execs `runsv` per service directory, looked up on PATH, and finit hands
        # services a deliberately bare one
        path = [ pkgs.runit ];
        log = true;
        command = "${lib.getExe' pkgs.runit "runsvdir"} /run/service";
      };

      environment.etc."services-switch".source = config.system.build.servicesSwitch;
    };

  testScript = ''
    def order():
        code, out = machine.execute("cat /run/svc-test/order")
        return out.strip().splitlines() if code == 0 else []

    machine.start()
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("runsvdir came up under finit"):
        machine.wait_until_succeeds("test -d /run/service/first/supervise", timeout=60)

    with subtest("every unit reached its latch"):
        for unit in ["start", "sysinit", "first", "second", "third"]:
            machine.wait_until_succeeds(
                f"test -e /run/providers-services/{unit}.ready", timeout=60
            )

    with subtest("synthesised edges held, despite runit starting everything at once"):
        # runit scans the whole directory and starts a runsv per service in parallel. without
        # the latch preamble these three would race; with it they cannot.
        assert order() == ["first", "second", "third"], f"order was {order()}"

    with subtest("the switch engine reconciles against runit"):
        out = machine.succeed("/etc/services-switch 2>&1")
        print(out)
        assert "starting:" not in out, f"engine wanted to start something: {out}"

        machine.succeed("sv stop /run/service/third")
        machine.sleep(2)
        out = machine.succeed("/etc/services-switch 2>&1")
        print(out)
        assert "third" in out, f"engine did not notice third: {out}"
        assert "second" not in out, f"engine disturbed second: {out}"

    machine.shutdown()
  '';
}
