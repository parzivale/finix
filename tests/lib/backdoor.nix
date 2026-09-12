# backdoor shell service for test driver communication
#
# this module provides a root shell accessible via virtconsole (/dev/hvc0),
# allowing the test driver to execute commands inside the vm
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.testing;

  qemuSerialDevice =
    if pkgs.stdenv.hostPlatform.isx86 then
      "ttyS0"
    else if pkgs.stdenv.hostPlatform.isAarch then
      "ttyAMA0"
    else
      throw "unknown QEMU serial device for ${pkgs.stdenv.hostPlatform.system}";

  # backdoor script based on NixOS test-instrumentation.nix
  # runs a non-interactive bash that reads commands from /dev/hvc0
  backdoorScript = pkgs.writeShellScript "backdoor" ''
    export USER=root
    export HOME=/root
    # through the symlink rather than the generation's own store path. Naming the store path
    # puts it in this script, and so in the unit's fingerprint - which means adding a package
    # anywhere changes the backdoor, the switch engine correctly restarts it, and the driver's
    # shell dies in the middle of the very command doing the switching. The symlink is the
    # same set of programs and does not move between generations.
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin

    # source profile if it exists
    if [[ -e /etc/profile ]]; then
      source /etc/profile 2>/dev/null || true
    fi

    # don't use a pager - commands are non-interactive
    export PAGER=

    cd /tmp

    # wait for hvc0 to be available
    while [[ ! -e /dev/hvc0 ]]; do
      sleep 0.1
    done

    # redirect stdin/stdout to virtio console
    exec < /dev/hvc0 > /dev/hvc0

    # wait for the serial console to be available, then redirect stderr to it
    # this matches NixOS behavior and avoids escape sequences from programs
    # like initctl being sent back through the backdoor
    while ! exec 2> /dev/${qemuSerialDevice}; do
      sleep 0.1
    done
    echo "connecting to host..." >&2

    # set raw mode to prevent CR/LF conversion
    stty -F /dev/hvc0 raw -echo

    # signal to test driver that shell is ready
    # NixOS test driver expects this exact message (capital S)
    echo "Spawning backdoor root shell..."

    # run a non-interactive bash that reads commands from /dev/hvc0
    # passing the device as argument makes bash run non-interactively
    # (avoids terminal control issues)
    PS1="" exec ${pkgs.bashNonInteractive}/bin/bash --norc /dev/hvc0
  '';

in
{
  options.testing.backdoor.enable = lib.mkEnableOption "backdoor shell service" // {
    default = true;
  };

  config = lib.mkIf (cfg.enable && cfg.backdoor.enable) {
    # ensure virtio_console module is loaded early
    boot.initrd.kernelModules = [ "virtio_console" ];

    environment.systemPackages = [
      pkgs.iproute2
      pkgs.iputils
    ];

    # finit has its own stanza vocabulary and this one predates the contract; more to the
    # point, `restart = 0` has no contract equivalent, and under finit that is what stops the
    # driver's shell being respawned after the test closes it.
    finit.services.backdoor = lib.mkIf (config.providers.services.backend == "finit") {
      description = "test driver backdoor shell";
      command = backdoorScript;
      runlevels = "234";
      log = false;

      # the backdoor runs bash which executes commands from hvc0 until EOF, then exits
      restart = 0;
    };

    # every other backend is PID 1 in its own right, so there is no finit to start this and
    # the driver never gets a shell - which looks like the machine failing to boot when it is
    # only the test harness missing. As a contract unit it comes up whichever init is running.
    providers.services.units.backdoor = lib.mkIf (config.providers.services.backend != "finit") {
      description = "test driver backdoor shell";
      type.service.command = backdoorScript;

      # late enough that a test seeing a shell can assume the system came up; the driver waits
      # for this to connect, so anything it looks at afterwards has had its chance to start
      requires = [ "multi-user" ];
    };
  };
}
