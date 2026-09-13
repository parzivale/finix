# what a rule does when the path is already there, and is not what it expects
#
# A VM boots into an empty world; a real machine boots into whatever the last install left.
# That difference hid a fault which made a laptop fail to boot while every test passed, so this
# puts the awkward cases on disk first and asserts that tmpfiles-setup survives all of them.
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
  name = "modules.tmpfiles-hostile-${backend}";

  nodes.machine =
    { config, ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      services.dbus.enable = true;
      services.iwd.enable = true;

      providers.services.units.booted = coreLib.bootedUnit;

      # runs before tmpfiles-setup, and makes the world hostile
      providers.services.units.hostile-state = {
        description = "leave the kind of mess a previous install leaves";
        requires = [ (lib.head config.providers.services.trunk.levels) ];

        type.oneshot.command = pkgs.writeShellScript "hostile-state" ''
          export PATH=${
            lib.makeBinPath [
              pkgs.coreutils
              pkgs.e2fsprogs
            ]
          }:$PATH

          # a dangling symlink where a directory is expected
          mkdir -p /var/lib
          ln -sfn /nonexistent /var/lib/iwd

          # a directory where a symlink is expected, again
          rm -rf /etc/machine-id
          mkdir -p /etc/machine-id

          # a file where a directory is expected
          mkdir -p /tmp
          : > /tmp/dbus
        '';
      };

      providers.services.tmpfiles.rules = [
        {
          type = "directory";
          path = coreLib.markerDir;
          mode = "1777";
        }
      ];
    };

  testScript = ''
    machine.start()

    with subtest("the boot survives every one of them"):
        machine.wait_until_succeeds("test -e ${coreLib.bootedMarker}", timeout=120)

    with subtest("and the log says which rules could not be applied, and what it found"):
        machine.succeed("cat /run/tmpfiles-setup.log >&2")

        log = machine.succeed("cat /run/tmpfiles-setup.log")
        assert "FAILED: directory rule for /tmp/dbus (found: regular" in log, log
        assert "FAILED: directory rule for /var/lib/iwd" in log, log

        # the one which used to succeed at the wrong thing: `ln -sfn` onto a directory links
        # inside it rather than replacing it, so /etc/machine-id became
        # /etc/machine-id/machine-id and nothing said a word. It is refused now.
        assert "FAILED: symlink rule for /etc/machine-id" in log, log
        machine.fail("test -e /etc/machine-id/machine-id")

        # and the rest of the rules ran: a failure is not an exit
        assert "done: " in log, log

    machine.shutdown()
  '';
}
