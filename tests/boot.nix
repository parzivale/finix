# test that the system boots successfully
#
# a minimal test that just verifies the vm boots to runlevel 2.
# useful for isolating boot issues from test driver issues.
{
  name = "boot";

  nodes.machine =
    { ... }:
    {
      services.mdevd.enable = true;

      # finit is PID 1 here: the contract needs a backend named before it can point boot.init
      # at one. getty supplies the terminal finix asserts exists - on finit it reduces to a
      # finit tty stanza, which is what a hand-written finit.ttys would have been.
      providers.services.backend = "finit";
      services.getty.enable = true;
    };

  testScript = ''
    machine.start()

    # wait for full boot sequence
    machine.wait_for_console_text("finix - stage 1")
    machine.wait_for_console_text("finix - stage 2")
    machine.wait_for_console_text("entering runlevel S")
    machine.wait_for_console_text("entering runlevel 2")
    # finit formats a tty stanza's progress line from the device path it opens, not from the
    # stanza's description - so this is `/dev/tty1` whether the description says so or not.
    machine.wait_for_console_text("getty on /dev/tty1")

    print("system booted to runlevel 2 successfully")

    machine.shutdown()
  '';
}
