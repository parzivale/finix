# services.openssh, on every implementation: a session opens
#
# The evaluation matrix says this module's units are coherent on all four inits. It cannot say
# whether sshd serves, and sshd is a good place to ask, because getting it wrong is quiet:
#
#   - `ssh-keygen` is a separate unit, and sshd requires it. Started in the wrong order, sshd
#     generates nothing, offers a host identity it then changes, and the first client to come
#     back sees a changed-key warning.
#   - readiness here is `waitFor.path` on /run/sshd.pid and not `waitFor.pidfile`, because `-D`
#     is sshd being told not to fork. Declared as a pidfile, dinit waits for a fork that never
#     comes and fails the unit on its start timeout.
#   - a login needs PAM, /etc/shadow, the setuid wrappers and the login program - a chain which
#     crosses most of early boot, and which no assertion about the unit graph touches.
#
# So the test logs in. Over the loopback rather than from a second node: what is being tested is
# the daemon and the session it opens, not the network, and a second VM per implementation is
# four more machines to boot for no more coverage.
{
  pkgs,
  lib,
  backend,
  ...
}:
let
  # a key pair baked into the image, so the test never needs a password or an interactive
  # prompt. Generated at build time and therefore fixed - which is fine for a machine that
  # exists for ninety seconds and is thrown away.
  keys =
    pkgs.runCommand "ssh-test-key"
      {
        nativeBuildInputs = [ pkgs.openssh ];
      }
      ''
        mkdir -p $out
        ssh-keygen -t ed25519 -N "" -C finix-test -f $out/id_ed25519
        cp $out/id_ed25519.pub $out/authorized_keys
      '';
in
{
  name = "modules.openssh-${backend}";

  nodes.machine =
    { ... }:
    {
      imports = [ (import ./base.nix { inherit backend; }) ];

      services.openssh.enable = true;
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e /etc/passwd", timeout=240)

    with subtest("the host keys are generated before anything serves with them"):
        # the keygen unit is a oneshot sshd requires, so by the time sshd is up this is true or
        # the ordering did not hold
        machine.wait_until_succeeds("test -s /var/lib/sshd/ssh_host_ed25519_key", timeout=120)

    with subtest("sshd is listening"):
        # the same file the unit's readiness waits for, asked independently
        machine.wait_until_succeeds("test -e /run/sshd.pid", timeout=120)
        machine.wait_until_succeeds("${lib.getExe' pkgs.netcat "nc"} -z 127.0.0.1 22", timeout=120)

    with subtest("a session opens, and runs as the user who logged in"):
        # both halves are copied out of the store rather than named there. sshd applies its
        # strict-mode check to the whole path of an authorized_keys file, and /nix/store is
        # mode 1775 - group-writable - so a key file inside it is refused and the client falls
        # back to asking for a password.
        machine.succeed("install -d -m 700 /root/.ssh")
        machine.succeed("install -m 600 ${keys}/authorized_keys /root/.ssh/authorized_keys")
        machine.succeed("install -m 600 ${keys}/id_ed25519 /root/.ssh/id_ed25519")

        # `-n` matters as much as the key does. The driver feeds commands to a shell reading
        # /dev/hvc0, and ssh without it reads that same stdin - so the session works, closes,
        # and the driver waits forever for output from a channel ssh has eaten.
        #
        # BatchMode so that a rejected key fails here rather than waiting out sshd's login
        # grace period on a prompt nothing will ever answer.
        who = machine.succeed(
            "ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
            " -o BatchMode=yes -o ConnectTimeout=10"
            " -i /root/.ssh/id_ed25519 root@127.0.0.1 id -un"
        ).strip()
        assert who == "root", f"the session belongs to {who}"

    with subtest("the daemon survives it"):
        # sshd forking a session per connection is normal; sshd going away with the session is
        # not, and would leave the pid file behind to hide it
        machine.succeed("kill -0 $(cat /run/sshd.pid)")

    machine.shutdown()
  '';
}
