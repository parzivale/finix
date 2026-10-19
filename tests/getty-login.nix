# logging in at a getty, and the shell staying there
#
# Every other test that enables getty stops at the prompt appearing: `Starting tty-tty1` on the
# console is taken as proof that terminals work. The prompt is the least of it. What a person
# does with one is type a name and a password and get a shell, and on hardware that shell was
# killed the instant it started - for every user, root included - and the prompt came back with
# nothing printed.
#
# finit's `log` was the cause: it forks a logger as a child of the getty's own process, which
# `login` inherits on exec and reaps in place of the shell - see `terminal` in
# providers.services. Nothing in the suite typed at a terminal, so nothing could have noticed.
#
# The marker file is the assertion, because it can only exist if a shell read a line from the
# terminal and ran it. A prompt redrawn after a successful login looks exactly like one redrawn
# after a failed one.
{
  name = "getty-login";

  nodes.machine =
    { pkgs, ... }:
    {
      services.mdevd.enable = true;
      providers.services.backend = "finit";
      services.getty.enable = true;

      # a keyboard for the driver to type on. The aarch64 `virt` machine has none by default -
      # only gpio-keys - so `send_chars` is QEMU pressing keys on nothing, and the prompt simply
      # never hears them
      virtualisation.qemu.extraArgs = [
        "-device"
        "virtio-keyboard-pci"
      ];

      # hunter2
      users.users.root.password = "$6$finixtest$XnkNVzZcIMosI5WKEF6TR4qvVcmPRQGzwoE0hpycLqVMHtufkCdmdnjGMhI1rIBwRLt6HSebAnSM.eDKf3ZmS/";

      # the case this was found on: an ordinary user whose login shell is fish, named as a package
      # the way that configuration does rather than through programs.fish
      users.users.vitrial = {
        isNormalUser = true;
        shell = pkgs.fish;
        password = "$6$finixtest$XnkNVzZcIMosI5WKEF6TR4qvVcmPRQGzwoE0hpycLqVMHtufkCdmdnjGMhI1rIBwRLt6HSebAnSM.eDKf3ZmS/";
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_console_text("Starting tty-tty1")
    machine.wait_until_tty_matches("1", "login: ", timeout=15)

    # the keyboard's driver is a module the device manager loads, which can land after the
    # prompt is drawn - and keys pressed before it exists are simply gone
    machine.wait_until_succeeds("grep -q 'Virtio Keyboard' /proc/bus/input/devices", timeout=15)

    with subtest("a login on tty1 gets a shell which reads from the terminal"):
        machine.send_chars("root\n")
        machine.wait_until_tty_matches("1", "Password: ", timeout=15)
        machine.send_chars("hunter2\n")
        machine.sleep(2)
        machine.send_chars("echo alive > /tmp/alive\n")
        machine.wait_for_file("/tmp/alive", timeout=15)

    with subtest("an ordinary user gets fish on tty2"):
        machine.send_key("alt-f2")
        machine.wait_until_succeeds("[ $(fgconsole) = 2 ]", timeout=15)
        machine.wait_until_tty_matches("2", "login: ", timeout=15)
        machine.send_chars("vitrial\n")
        machine.wait_until_tty_matches("2", "Password: ", timeout=15)
        machine.send_chars("hunter2\n")
        machine.sleep(3)
        machine.send_chars("echo $FISH_VERSION > /tmp/fish\n")
        machine.wait_for_file("/tmp/fish", timeout=15)
        machine.succeed("[ -s /tmp/fish ]")
        machine.succeed("[ $(stat -c %U /tmp/fish) = vitrial ]")

    with subtest("finit is not capturing the terminal's output"):
        machine.fail("grep -qw log /etc/finit.d/tty-tty1.conf")

    machine.shutdown()
  '';
}
