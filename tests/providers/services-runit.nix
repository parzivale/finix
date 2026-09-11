# the providers.services contract driven on runit
#
# runit boots this machine: `runit-init` is PID 1, and it runs the three stage scripts runit
# expects - setup, then runsvdir, then teardown. Selecting the backend is the whole of what
# this configuration says about init, and nothing in it mentions finit.
#
# this is the backend whose target cannot do what the contract asks. runit has no
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

      # one choice: what supervises the units is also what the kernel starts
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
