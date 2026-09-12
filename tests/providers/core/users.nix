# a unit which asks to run as someone runs as them
#
# Every implementation claims this - `supportedFeatures.user` is true on all four - but each
# arranges it differently: finit and dinit have it as a property of a service, runit borrows
# `chpst`, and s6 wraps the command in `s6-setuidgid`. An implementation which quietly ignored
# the request would run the unit as root, which is more privilege than was asked for rather than
# less, and nothing in the unit's own behaviour would show it.
#
# So the unit reports who it actually is, and the test reads it back.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };

  # writes down the name it is really running under. `id -un` rather than $USER, which is
  # whatever the supervisor happened to export.
  whoami =
    name:
    pkgs.writeShellScript "whoami-${name}" ''
      ${coreLib.preamble}
      ${lib.getExe' pkgs.coreutils "id"} -un > ${coreLib.markerDir}/${name}.user
      exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
    '';
in
{
  name = "providers.users-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      users.users.alice = {
        isNormalUser = true;
        uid = 3001;
      };

      providers.services.units = {
        as-alice = {
          type.service.command = whoami "as-alice";
          user = "alice";
          requires = [ "sysinit" ];
        };

        # the control. Without it, an implementation which ran everything as root would pass
        # nothing here - but one which ran everything as alice would also look correct.
        as-root = {
          type.service.command = whoami "as-root";
          requires = [ "sysinit" ];
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("both units ran"):
        for name in ["as-alice", "as-root"]:
            machine.wait_until_succeeds(f"test -e ${coreLib.markerDir}/{name}.user", timeout=120)

    with subtest("the one that asked for a user runs as that user"):
        who = marker("as-alice.user")
        assert who == "alice", (
            f"the unit asked to run as alice and ran as {who} - unhonoured, this is more "
            "privilege than was asked for, not less"
        )

    with subtest("and the one that asked for nothing still runs as root"):
        who = marker("as-root.user")
        assert who == "root", f"a unit which named no user ran as {who}"

    machine.shutdown()
  '';
}
