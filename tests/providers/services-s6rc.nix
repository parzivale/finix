# the providers.services contract driven on s6-rc
#
# note what this configuration does not contain: anything about finit. It names what is PID 1
# and what supervises the units, and the rest follows - s6-rc says how it wants to be run, and
# whatever is PID 1 runs it. Swapping the init here would need no other change.
#
# s6-rc is worth testing because it differs from the others in three ways.
#
# its configuration is compiled: `s6-rc-compile` turns a source tree into a binary database
# inside a Nix derivation, so a malformed graph fails the build rather than the boot. Every
# other implementation discovers that on the machine - dinit by exiting 0 without explanation,
# finit by logging a parse error to a console nobody is reading.
#
# it speaks s6 readiness natively. `beta` below waits before notifying and `gamma` requires it,
# so if that notification were not being observed gamma would start early and the recorded
# order would say so.
#
# and its dependencies order change operations without propagating stops, which is the
# contract's start-only edge with no emulation at all - only dinit otherwise manages that.
#
# It also has no logging of its own for a unit: left alone, output goes to s6-linux-init's
# catch-all logger and from there to the console. So the system log is checked here too, for
# a service and a oneshot both, since the backend has to arrange that itself.
{
  name = "providers.services-s6rc";

  nodes.machine =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      note = text: ''
        ${pkgs.coreutils}/bin/mkdir -p /run/svc-test
        ${pkgs.coreutils}/bin/printf '%s\n' ${text} >> /run/svc-test/order
      '';
    in
    {
      services.mdevd.enable = true;
      services.getty.enable = true;

      # the harness sends all of syslog to the console, which is also where s6's catch-all logger
      # copies everything - so the console cannot say which of the two a line came through. A
      # file only syslogd writes to can.
      services.sysklogd.extraConfig = "*.* /var/log/units";

      environment.systemPackages = [
        pkgs.s6
        pkgs.s6-rc
      ];

      # one choice: what supervises the units is also what the kernel starts
      providers.services.backend = "s6-rc";

      providers.services.units = {
        alpha = {
          type.service.command = pkgs.writeShellScript "alpha" ''
            echo "alpha-to-syslog"
            ${note "alpha"}
            exec ${pkgs.coreutils}/bin/sleep infinity
          '';
          requires = [ "sysinit" ];
        };

        # readiness over s6's own protocol, deliberately late: anything requiring this must
        # wait for the notification rather than for the process appearing
        beta = {
          type.service = {
            readiness = "s6";
            command = pkgs.writeShellScript "beta" ''
              ${pkgs.coreutils}/bin/sleep 3
              ${note "beta-ready"}
              printf '\n' >&3
              exec ${pkgs.coreutils}/bin/sleep infinity
            '';
          };
          requires = [ "alpha" ];
        };

        gamma = {
          type.service.command = pkgs.writeShellScript "gamma" ''
            ${note "gamma"}
            exec ${pkgs.coreutils}/bin/sleep infinity
          '';
          requires = [ "beta" ];
        };

        # a oneshot runs through s6-rc's runner rather than under a supervisor, so its output
        # takes a different road to the same place
        delta = {
          type.oneshot.command = pkgs.writeShellScript "delta" ''
            echo "delta-to-syslog" >&2
          '';
          requires = [ "sysinit" ];
        };
      };

      environment.etc."services-switch".source = config.system.build.servicesSwitch;
    };

  testScript = ''
    def order():
        code, out = machine.execute("cat /run/svc-test/order")
        return out.strip().splitlines() if code == 0 else []

    machine.start()

    with subtest("whatever is PID 1 brought the supervisor up"):
        machine.wait_until_succeeds(
            "s6-rc -l /run/s6-rc list | grep -q gamma", timeout=180
        )

    with subtest("s6 readiness was observed, not assumed"):
        # beta waits three seconds before notifying, and gamma requires beta - so gamma may
        # only appear after beta-ready. Were the notification ignored, beta would count as up
        # the moment it spawned and gamma would race ahead of it.
        assert order() == ["alpha", "beta-ready", "gamma"], f"order was {order()}"

    with subtest("a unit's output reaches the system log, tagged with its name"):
        # stdout for the service, stderr for the oneshot: both are redirected, and either one
        # missing would be a unit whose errors still go only to the console
        for unit in ["alpha", "delta"]:
            machine.wait_until_succeeds(
                f"grep -qs '{unit}: {unit}-to-syslog' /var/log/units", timeout=60
            )

    with subtest("the switch engine reconciles against s6-rc"):
        out = machine.succeed("/etc/services-switch 2>&1")
        print(out)
        assert "starting:" not in out, f"engine wanted to start something: {out}"

        machine.succeed("s6-rc -l /run/s6-rc -d change gamma")
        machine.sleep(2)
        out = machine.succeed("/etc/services-switch 2>&1")
        print(out)
        assert "gamma" in out, f"engine did not notice gamma: {out}"
        assert "alpha" not in out, f"engine disturbed alpha: {out}"

    machine.shutdown()
  '';
}
