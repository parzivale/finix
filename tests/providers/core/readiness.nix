# a unit requiring another does not start until that other is genuinely ready
#
# Ordering says the edges hold. This says what the edge means: not "the process has been
# spawned" but "the thing it provides is live". The difference is invisible on a daemon which is
# useful the instant it forks, and is the whole game on one which is not.
#
# Both kinds used here are ones every implementation offers - `waitFor.path` and
# `waitFor.check`. The protocols which need the daemon's cooperation, `notify` and `s6`, are
# deliberately not here: only finit and s6-rc can observe them, so a core test asking for one
# would not be a core test. Each backend's own test covers those.
#
# Each daemon sleeps before it becomes live, so a dependant which started without waiting has
# time to be caught doing it: it writes down whether what it required was there when it ran.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };

  delay = 3;

  liveFile = name: "${coreLib.markerDir}/${name}.live";
in
{
  name = "providers.readiness-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        # ready when a file it creates appears
        by-path = {
          type.service = {
            command = coreLib.slowDaemon "by-path" delay;
            readiness.waitFor.path.path = liveFile "by-path";
          };
          requires = [ "sysinit" ];
        };

        after-path = {
          type.service.command = coreLib.observer "after-path" (liveFile "by-path");
          requires = [ "by-path" ];
        };

        # ready when a command run against it returns. The command does the waiting, and its
        # return is the readiness - which is what makes this the general case of the others.
        by-check = {
          type.service = {
            command = coreLib.slowDaemon "by-check" delay;
            readiness.waitFor.check.command = pkgs.writeShellScript "await-by-check" ''
              until [ -e ${liveFile "by-check"} ]; do
                ${lib.getExe' pkgs.coreutils "sleep"} 0.1
              done
            '';
          };
          requires = [ "sysinit" ];
        };

        after-check = {
          type.service.command = coreLib.observer "after-check" (liveFile "by-check");
          requires = [ "by-check" ];
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("both dependants eventually ran"):
        for name in ["after-path", "after-check"]:
            machine.wait_until_succeeds(f"test -e ${coreLib.markerDir}/{name}.saw", timeout=120)

    with subtest("waitFor.path held its dependant until the path was there"):
        saw = marker("after-path.saw")
        assert saw == "yes", (
            f"after-path started before by-path was live (saw {saw}) - the edge was "
            "satisfied by the process existing rather than by it being ready"
        )

    with subtest("waitFor.check held its dependant until the check returned"):
        saw = marker("after-check.saw")
        assert saw == "yes", (
            f"after-check started before by-check was live (saw {saw})"
        )

    machine.shutdown()
  '';
}
