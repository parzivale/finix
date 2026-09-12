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

      providers.services.units =
        let
          # each records its name the moment it starts, so the file is a record of the order
          # runit actually brought them up in.
          #
          # Everything is named absolutely, including the mkdir: a run script inherits whatever
          # environment runsvdir was given, and these units set no `path`, so there is no PATH
          # to resolve a bare command through. Nothing else creates the directory either - the
          # append alone leaves the file missing and the order unobservable.
          recorder =
            name:
            pkgs.writeShellScript name ''
              ${lib.getExe' pkgs.coreutils "mkdir"} -p /run/svc-test
              echo ${name} >> /run/svc-test/order
              exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
            '';
        in
        {
          first = {
            type.service.command = recorder "first";
            requires = [ "sysinit" ];
          };

          second = {
            type.service.command = recorder "second";
            requires = [ "first" ];
          };

          third = {
            type.service.command = recorder "third";
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

    # runit is PID 1 here, so there is no finit runlevel to wait for - `entering runlevel 2`
    # is a finit message, and waiting for one on this machine blocks until the test times out.
    # What follows gates on runit's own progress instead.
    machine.wait_for_console_text("runit: enter stage: /etc/runit/2")

    with subtest("runsvdir came up"):
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
