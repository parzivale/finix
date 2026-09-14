{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ../providers/core/lib.nix { inherit pkgs lib; };
in
{
  name = "modules.dbus-${backend}";

  nodes.machine =
    { config, ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      services.dbus.enable = true;

      # the bus, wrapped so that each start leaves a mark.
      #
      # Counting starts is the only reliable evidence that the ordering held. The failure
      # message is not: dbus reports it through /dev/log, and syslogd is in the same tier, so
      # when syslogd has not started yet the message goes nowhere at all - a run against the
      # broken tree restarted dbus five times and logged none of it. Timing is not either: a
      # restarted bus is still older than the boot marker.
      #
      # The flags are restated rather than read from the module, because reading the option
      # being overridden here is a definition in terms of itself. If they drift, this wrapper
      # runs a bus the module would not have.
      providers.services.units.dbus.type.service.command = lib.mkForce (
        pkgs.writeShellScript "dbus-counted" ''
          echo start >> /run/dbus-starts
          ${config.services.dbus.package}/bin/dbus-uuidgen --ensure
          exec ${config.services.dbus.package}/bin/dbus-daemon --nofork --system --syslog-only
        ''
      );

      # the harness sends syslog to the console, which a test can watch go past but cannot ask
      # a question of afterwards. This keeps a copy in a file, because the thing being asserted
      # below is the *absence* of a message - and absence is not something wait_for_console_text
      # can answer.
      environment.etc."syslog.conf".source = lib.mkForce (
        pkgs.writeText "syslog.conf" ''
          *.* /dev/console

          # /run, not /var/log: /var/log is itself created by tmpfiles-setup, which is one of
          # the units this test is about, so a log file under it would be missing exactly when
          # the race it is meant to catch happens. /run is mounted before any unit runs.
          *.* -/run/messages
        ''
      );

      providers.services.units.booted = coreLib.bootedUnit;

      # `mkMerge` of two definitions rather than one list: a priority wrapper applies to a whole
      # definition, so `[ … ] ++ lib.mkOrder 600 [ … ]` is not a list at all - it evaluates to
      # "expected a list but found a set", and does it while computing an assertion, which is
      # far from where it was written.
      providers.services.tmpfiles.rules = lib.mkMerge [
        [
          {
            path = coreLib.markerDir;
            type.directory.mode = "1777";
          }
        ]
        # and a thousand directories nobody wants, to make the race decidable.
        #
        # The bug this test exists for is dbus starting before /run/dbus is created. That is a
        # race, and on a fast machine tmpfiles-setup usually wins it - a run against the broken
        # tree failed twice and then passed, which is the worst possible behaviour for a
        # regression test. Giving tmpfiles-setup a second of real work makes it lose reliably, so
        # a dbus which is not ordered after it fails every time.
        #
        # `mkOrder 600` puts these after the base layout and before dbus's own rules, which is
        # where the delay has to be: after them and dbus's directory would already exist.
        (lib.mkOrder 600 (
          lib.genList (i: {
            type = "directory";
            path = "/run/tmpfiles-ballast/${toString i}";
          }) 1000
        ))
      ];
    };

  testScript = ''
    machine.start()

    with subtest("userspace comes up and the bus is answering"):
        machine.wait_until_succeeds("test -e ${coreLib.bootedMarker}", timeout=90)
        machine.succeed("test -S /run/dbus/system_bus_socket")

    with subtest("and it never failed to bind on the way there"):
        # the assertion that matters, and the one the obvious version of this test does not
        # make. dbus attaches to the head of the trunk, and so does the unit which creates
        # /run/dbus - so the bus used to race it, die on this message, and be restarted until
        # the directory existed. Both checks above passed throughout: a supervisor which
        # restarts a service turns an ordering bug into a slow boot and nothing else.
        #
        # Timing cannot substitute for this. A restarted dbus is still older than the boot
        # marker, so comparing the two proves nothing - the first thing written here did
        # exactly that and passed against the broken tree.
        starts = int(machine.succeed("wc -l < /run/dbus-starts").strip())
        assert starts == 1, f"the bus was started {starts} times"

    machine.shutdown()
  '';
}
