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
      # at one. getty supplies the terminal finix asserts exists - an ordinary `providers.services`
      # unit like any other, requiring `multi-user`.
      providers.services.backend = "finit";
      services.getty.enable = true;
    };

  testScript = ''
    machine.start()

    # wait for full boot sequence
    machine.wait_for_console_text("finix - stage 1")
    machine.wait_for_console_text("finix - stage 2")
    machine.wait_for_console_text("entering runlevel S")
    # boot-side stanzas sit in every runlevel from 1 to 9, not S, so nothing the graph attaches
    # - getty included - starts until finit has actually made the jump to the configured
    # runlevel. `entering runlevel 2` comes first now, not last.
    machine.wait_for_console_text("entering runlevel 2")
    # bootstrap finalizes as soon as it reaches the configured runlevel now, which is also what
    # turns finit's own progress display off - so everything the graph starts from here on,
    # tty included, is a plain syslog line (`Starting tty-tty1[<pid>]`) rather than the
    # `[ ⋯ ] description [ OK ]` spinner text bootstrap-side units still get.
    machine.wait_for_console_text("Starting tty-tty1")

    print("system booted to runlevel 2 successfully")

    machine.shutdown()
  '';
}
