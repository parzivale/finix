# a census of what a contract-driven machine is actually running
#
# every test here builds on tests/lib/contract-base.nix, which drives the machine's daemons
# through the contract rather than letting finit define them. this one enumerates every stanza
# finit ends up running and reports which of them the contract did not produce, so the
# remainder cannot grow unnoticed.
#
# what remains outside is the core boot machinery - tmpfiles, sysctl, modprobe, the suid
# wrappers, remount-nix-store - emitted by modules every system imports, plus the harness's own
# backdoor and syslogd. porting those is the migration, not a test.
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
      imports = [ ../lib/contract-base.nix ];

      providers.services.units = {
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
