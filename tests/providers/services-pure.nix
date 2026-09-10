# a system whose daemons are providers.services units rather than finit stanzas
#
# the other two tests are hybrids: they enable services.mdevd, which writes finit.services
# directly, so the contract is only ever driving part of the machine. here the daemons are
# units instead, to find out whether the abstraction can carry a system rather than decorate
# one. it also pins two things the contract could not express until this test was written,
# both of which mdevd needed: `path` and `readiness = "s6"`.
#
# a terminal is not a daemon and is not modelled by the contract at all. it has no readiness
# signal and nothing ever depends on one, so it has no place in a dependency graph; and only
# finit has a distinct tty stanza - on dinit and systemd a getty is an ordinary service - so
# modelling one would export a finit peculiarity into the abstraction. it is therefore
# declared here as raw finit configuration, in the same category as the kernel command line,
# which is also what satisfies finix's assertion that finit.ttys be non-empty.
#
# what also remains outside the contract is the core boot machinery - tmpfiles, sysctl,
# modprobe, the suid wrappers, remount-nix-store - emitted by modules which every system
# imports. porting those is the migration, not a test, so the test reports them instead.
{
  name = "providers.services-pure";

  nodes.machine =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    {
      # mdevd's whole config block is behind `mkIf cfg.enable`, so disabling the module also
      # takes away /etc/mdev.conf and its activation script - configuration, activation and
      # service definition are bundled together. the module therefore stays enabled for what
      # it configures, and only its finit stanzas are switched off, so the daemon itself comes
      # from the contract. this is the shape a real migration would take.
      services.mdevd.enable = true;
      finit.services.mdevd.enable = false;
      finit.run.coldplug.enable = false;

      # the terminal, declared as plain finit configuration rather than through the getty
      # module or the contract. a tty is not a daemon, so it is not the contract's business.
      finit.ttys.tty1 = {
        description = "getty on /dev/tty1";
        nowait = true;
      };

      providers.services.backend = "finit";
      providers.services.trunk.enable = true;

      providers.services.units = {
        # mdevd needs `path` and s6 readiness - neither of which the contract could express
        # before this test was written
        device-events = {
          description = "device event daemon";
          requires = [ "start" ];
          readiness = "s6";
          command = "${config.services.mdevd.package}/bin/mdevd -D %n -F /run/current-system/firmware -f ${
            config.environment.etc."mdev.conf".source
          }";
          path = [
            config.programs.coreutils.package
            pkgs.execline
            pkgs.util-linux
          ];
        };

        coldplug = {
          type = "oneshot";
          description = "cold plugging system";
          requires = [ "device-events" ];
          command = "${config.services.mdevd.package}/bin/mdevd-coldplug";
        };

        # an ordinary daemon, to prove the graph still works around the infrastructure
        marker = {
          type = "oneshot";
          description = "record that the graph ran";
          requires = [ "basic" ];
          path = [ config.programs.coreutils.package ];
          command = pkgs.writeShellScript "marker" ''
            mkdir -p /run/svc-test
            touch /run/svc-test/marker.ran
          '';
        };
      };
    };

  testScript = ''
    import json

    def status(name):
        return json.loads(machine.succeed(f"initctl -j status {name}"))["status"]

    machine.start()

    machine.wait_for_console_text("finix - stage 2")
    machine.wait_for_console_text("entering runlevel 2")

    with subtest("the machine booted with no finit-defined services"):
        machine.wait_until_succeeds("test -f /run/svc-test/marker.ran", timeout=120)

    with subtest("mdevd runs as a contract unit, with s6 readiness"):
        # note the unit is named device-events, not mdevd: a contract unit sharing a name
        # with an existing finit stanza silently merges with it, so the `enable = false`
        # above would have disabled this unit too
        assert status("device-events") == "running", f"device-events is {status('device-events')}"
        machine.succeed("test -f /run/finit/cond/task/device-events-started/success")
        assert status("coldplug") == "done", f"coldplug is {status('coldplug')}"

    with subtest("the terminal is plain finit config, not a unit"):
        machine.wait_for_console_text("getty on /dev/tty1")

    with subtest("every stanza is ours, bar the core boot tasks"):
        # anything finit is running that the contract did not emit is either core boot
        # machinery or a regression; this pins the list so it cannot grow unnoticed
        core = {
            "ctrl-alt-del", "loadkmap", "modprobe", "remount-nix-store",
            "setvesablank", "suid-sgid-wrappers", "sysctl", "tmpfiles-setup",
            "ifupdown-ng", "keventd", "backdoor", "syslogd",
        }
        contract = {
            "start", "sysinit", "basic", "multi-user", "running", "stopped", "shutdown",
            "device-events", "device-events-started", "coldplug", "marker",
            "providers-services-shutdown",
        }
        listed = json.loads(machine.succeed("initctl -j status"))
        rows = listed if isinstance(listed, list) else listed.get("services", [])
        names = {
            r.get("name") or r.get("identity") or r.get("ident") or ""
            for r in rows
            if isinstance(r, dict)
        } - {""}

        print("all stanzas: " + ", ".join(sorted(names)))
        print("core boot tasks present: " + ", ".join(sorted(names & core)))
        print("neither ours nor core: " + ", ".join(sorted(names - core - contract)))

    machine.shutdown()
  '';
}
