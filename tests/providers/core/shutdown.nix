# the machine goes down, and the units that asked to run on the way out do
#
# Two claims, and they fail differently.
#
# The first is that `poweroff` powers the machine off. Each implementation ships its own, each
# talks only to its own init, and the wrong one reports a failure and leaves the machine
# running - which is not a test failure but a hang, since a driver waiting for a VM that will
# never stop waits forever.
#
# The second is the shutdown side of the graph. A level at or after the latch cannot be reached
# while the system is up, so a unit attached to one runs only on the way down; two of them in
# sequence say the sequence runs to its end rather than being cut off partway by the power
# going. Both report over /dev/console, because by then /run is going away and the driver's own
# shell is among the things being stopped.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  coreLib = import ./lib.nix { inherit pkgs lib; };

  # reports twice: to the console, which is the only thing still listening once /run is going
  # away, and to a marker, which is what can be checked while the system is still up.
  step =
    name: text:
    pkgs.writeShellScript "shutdown-${name}" ''
      # the console write comes first, and deliberately: by this point /run is going away and
      # the marker is the part most likely to fail, so doing it first would let it take the
      # evidence with it.
      echo "${text}" > /dev/console
      ${coreLib.preamble}
      ${lib.getExe' pkgs.coreutils "touch"} ${coreLib.markerDir}/${name}.ran
    '';
in
{
  name = "providers.shutdown-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend coreLib; }) ];

      providers.services.units = {
        # an ordinary boot-side daemon, so the shutdown side has something to have stopped
        running-daemon = {
          type.service.command = coreLib.daemon "running-daemon";
          requires = [ "sysinit" ];
        };

        # the two attach to different levels, which is what orders them. Attaching both to
        # `stopped` would make them siblings with no edge between them, and nothing in the
        # contract would say which ran first - finit would order them anyway, because it
        # collapses the shutdown side into one script, and dinit would not.
        first-down = {
          requires = [ "stopped" ];
          type.oneshot.command = step "first-down" "CORE-SHUTDOWN-ONE";
        };

        # reports whether the earlier step had already run, rather than relying on the order
        # two console lines happen to be read in. This is the ordering claim itself: the marker
        # can only be there if the level before this one was reached first.
        then-down = {
          requires = [ "shutdown" ];
          type.oneshot.command = pkgs.writeShellScript "shutdown-then-down" ''
            if [ -e ${coreLib.markerDir}/first-down.ran ]; then
              echo "CORE-SHUTDOWN-TWO after-one" > /dev/console
            else
              echo "CORE-SHUTDOWN-TWO alone" > /dev/console
            fi
            ${coreLib.preamble}
            ${lib.getExe' pkgs.coreutils "touch"} ${coreLib.markerDir}/then-down.ran
          '';
        };
      };
    };

  testScript = ''
    ${coreLib.prelude}

    machine.start()
    wait_booted()

    with subtest("the machine is up, with its boot-side daemon running"):
        machine.wait_until_succeeds("pgrep -f '[f]inix-daemon-running-daemon'", timeout=60)

    with subtest("the shutdown side has not run while the system is up"):
        # the latch is the one level the graph cannot reach on its own: if these had run
        # already, the level would mean nothing and a shutdown unit would be an ordinary one
        machine.fail("test -e ${coreLib.markerDir}/first-down.ran")
        machine.fail("test -e ${coreLib.markerDir}/then-down.ran")

    # backgrounded and unchecked: this takes the driver's own shell down with the machine, so
    # there is nothing left to report an exit status to. `poweroff` rather than any particular
    # init's command - which is the assertion that the selected backend's own is what a bare
    # poweroff reaches.
    machine.execute("(poweroff &) >/dev/null 2>&1", check_return=False)

    with subtest("the shutdown sequence runs to completion, in order"):
        # over the console: /run is going away by now, and the shell that would have read a
        # marker file is itself one of the things being stopped.
        #
        # neither marker is a prefix of the other, so waiting for the first cannot be satisfied
        # by the second having arrived already - which is what made an earlier version of this
        # report success against a machine that ran them backwards.
        machine.wait_for_console_text("CORE-SHUTDOWN-ONE")

        # `after-one` rather than the bare marker: the second step says for itself whether the
        # first had run, so this does not depend on the order two console lines are read in.
        # An earlier version waited for two markers where one was a prefix of the other, and
        # passed against a machine that ran them backwards.
        machine.wait_for_console_text("CORE-SHUTDOWN-TWO after-one")

    with subtest("and the machine actually powers off"):
        # the failure this catches is not a wrong answer but a hang: a poweroff which cannot
        # reach its init reports an error and leaves the machine running
        machine.wait_for_shutdown()
  '';
}
