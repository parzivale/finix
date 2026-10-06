# which tree a bare unit name means, when the machine has more than one
#
# `initctl` resolves a name against an index built at evaluation time, so it can answer "who owns
# `agent`" without opening a conversation with every supervisor on the machine - and can refuse an
# ambiguous name rather than acting on whichever one happened to answer first. That resolution is
# the only real logic in the tool, and it had no test at all: the core suite covers the system
# tree, which is the case where resolution has nothing to decide.
#
# finit is pid 1 and dinit supervises the users, which is the combination `services-users-split`
# already establishes. Nothing here starts a session, and nothing needs to: resolution reads the
# index, not the supervisors, so every claim below is about which command `initctl` decided to
# reach for. Where a user tree is chosen the attempt then fails, there being no socket to talk to -
# and that failure is the evidence, because it is a different failure from the refusal to choose.
{
  name = "providers.initctl-trees";

  nodes.machine =
    {
      pkgs,
      lib,
      ...
    }:
    let
      daemon =
        name:
        pkgs.writeShellScript name ''
          exec ${lib.getExe' pkgs.coreutils "sleep"} infinity
        '';
    in
    {
      imports = [ ../lib/contract-base.nix ];

      environment.systemPackages = [ pkgs.dinit ];

      providers.services.user.backend = "dinit";

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };

      users.users.bob = {
        group = "users";
        home = "/home/bob";
        uid = 3002;
      };

      # in the system tree and in alice's, which is the case the preference order exists for.
      providers.services.units.shared = {
        type.service.command = daemon "shared-system";
        requires = [ "sysinit" ];
      };

      # `agent` is in both user trees and in neither the system's, which is the case nothing can
      # decide: there is no preference to apply and two candidates remain.
      providers.services.users.alice.units = {
        agent = {
          type.service.command = daemon "alice-agent";
          requires = [ ];
        };
        shared = {
          type.service.command = daemon "alice-shared";
          requires = [ ];
        };
      };

      providers.services.users.bob.units.agent = {
        type.service.command = daemon "bob-agent";
        requires = [ ];
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_console_text("entering runlevel 2")

    # `entering runlevel 2` is finit saying it has reached the level, not that everything attached
    # to it has started - the system unit below is still queued at that point, and an earlier
    # version of this asserted against it 3.8 seconds into the boot and read an empty state.
    #
    # Waited for rather than asserted, because every claim in this file is about which tree a name
    # resolves to, and none of them is about how quickly a daemon comes up.
    machine.wait_until_succeeds("initctl status shared | grep -qx running", timeout=90)


    def stderr(command):
        _, out = machine.execute(f"{command} 2>&1 >/dev/null")
        return out


    with subtest("a name in the system tree and a user's resolves to the system's"):
        # the preference order is the caller's own tree, then the system's. Run as root, which
        # owns no tree, that is the system - and it has to be, because the alternative is a tool
        # which answers about somebody else's units when asked without qualification.
        assert machine.succeed("initctl status shared").strip() == "running"

    with subtest("a name in two user trees and neither the system's is refused, not guessed"):
        # the whole reason the index exists. Acting on whichever supervisor answered first would
        # be a tool that does something different depending on timing.
        machine.fail("initctl status agent")

        err = stderr("initctl status agent")
        assert "alice" in err and "bob" in err, err

    with subtest("--user picks one of them, and the refusal goes away"):
        # it still fails - alice has no session, so there is no supervisor to reach - but it is a
        # different failure, and that is the assertion: the ambiguity was resolved before anything
        # was attempted.
        machine.fail("initctl status agent --user alice")

        err = stderr("initctl status agent --user alice")
        assert "bob" not in err, err

    with subtest("--user also overrides the system tree, rather than being ignored"):
        # `shared` resolves to the system tree unqualified, just asserted. Naming alice has to
        # change that, or the flag means nothing for exactly the names where it matters most.
        machine.fail("initctl status shared --user alice")

    with subtest("a name absent from the named tree is refused, naming the tree"):
        machine.fail("initctl status shared --user bob")

        err = stderr("initctl status shared --user bob")
        assert "bob" in err, err

    with subtest("--user is honoured wherever it appears in the arguments"):
        # the recorded bug: the flag was recognised immediately after the command and silently
        # ignored anywhere else, so this form answered about the system unit as though it had not
        # been given. Both forms must now agree - and for `shared`, agreeing means both failing,
        # because the system answer is the wrong one.
        machine.fail("initctl --user alice status shared")
        machine.fail("initctl status shared --user alice")

        assert stderr("initctl --user alice status agent") == stderr(
            "initctl status agent --user alice"
        )
  '';
}
