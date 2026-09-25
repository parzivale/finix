# the layer which turns a machine's configuration into one that can boot in qemu
#
# `qemu.nix` beside this describes the virtual machine: the argv, the 9p store share, the
# virtio drivers. What it does not do is take anything away, which is what a configuration
# describing real hardware needs. Cerberus names a btrfs root on a disko layout; the macbook
# names three partitions on an nvme device that only exists inside one particular laptop.
# Neither is attached to a qemu, so both have to be replaced rather than added to - and
# replacing is the whole of what this file does.
#
# It is never part of a machine's own evaluation. `build-vm.nix` evaluates the machine a second
# time with this on top, which is why the overrides here can be blunt: nothing downstream of
# them is the system that gets deployed.
{
  config,
  options,
  pkgs,
  lib,
  ...
}:
let
  hostPkgs = config.virtualisation.host.pkgs;

  # The console the kernel is told to use, which is the console the runner below reads. Chosen
  # by architecture because qemu's `virt` machine wires a different uart depending: an amba
  # pl011 on aarch64, a 16550 on x86.
  serial =
    if pkgs.stdenv.hostPlatform.isx86 then
      "ttyS0"
    else if pkgs.stdenv.hostPlatform.isAarch then
      "ttyAMA0"
    else
      throw "no known qemu serial device for ${pkgs.stdenv.hostPlatform.system}";

  name = config.networking.hostName;

  runner = hostPkgs.writeShellApplication {
    name = "run-${name}-vm";

    runtimeInputs = [ hostPkgs.coreutils ];

    text = ''
      # Somewhere for qemu to put anything it wants to write. Nothing needs it while the root
      # is a tmpfs and the store arrives over 9p, but qemu is given a working directory rather
      # than whatever the caller happened to be in.
      if [ -z "''${VM_STATE_DIR-}" ]; then
        VM_STATE_DIR="$(mktemp -d -t ${name}-vm.XXXXXX)"
        trap 'rm -rf "$VM_STATE_DIR"' EXIT
      else
        mkdir -p "$VM_STATE_DIR"
      fi

      cd "$VM_STATE_DIR"

      echo "${name}: console on this terminal; C-a x to quit" >&2

      exec ${lib.escapeShellArgs config.virtualisation.qemu.argv} "$@"
    '';
  };
in
{
  imports = [ ./qemu.nix ];

  config = {
    # The root, and nothing else. A machine's other mounts are not translated into anything -
    # `/persistent`, `/boot` and the rest simply are not there, and a service which wants one
    # finds an ordinary directory on the tmpfs instead. Which is usually what a test of that
    # service wants; where it is not, name the mount:
    #
    #   virtualisation.vmVariant.virtualisation.fileSystems."/persistent" = {
    #     device = "tmpfs"; fsType = "tmpfs"; neededForBoot = true;
    #   };
    virtualisation.fileSystems."/" = {
      device = "tmpfs";
      fsType = "tmpfs";
      options = [ "mode=755" ];
    };

    # The override, in one definition, for the reason `virtualisation.fileSystems` exists: a
    # definition at this priority discards every lower-priority one rather than merging, so
    # everything the machine is to mount has to be in the set being installed here.
    fileSystems = lib.mkVMOverride config.virtualisation.fileSystems;

    # A swapfile on a filesystem which is not mounted, or a partition on a disk which is not
    # attached. Either way there is nothing to swap to.
    swapDevices = lib.mkVMOverride [ ];

    # Nothing installs a bootloader here: the kernel and initrd are handed to qemu directly, so
    # there is no ESP to install into and activation would fail trying. Said as the contract
    # rather than as any particular implementation's `enable`, so this holds for a machine
    # whichever loader it uses - and for one which has no bootloader module imported at all.
    providers.bootloader.backend = lib.mkVMOverride "none";

    # The kernel talks to the terminal the runner is attached to, and qemu is told not to open a
    # window. Together these are what make `run-<host>-vm` behave like a program rather than
    # like a desktop application.
    boot.kernelParams = [ "console=${serial},115200n8" ];
    virtualisation.qemu.extraArgs = [ "-nographic" ];

    # User-mode networking: a NAT the guest reaches the outside through, needing no privileges
    # and no setup on the host. Not the vde switches the test harness builds - those exist so
    # that several machines can see each other, which a single interactive machine does not
    # need.
    virtualisation.qemu.nics.user.args = [
      "user"
      "model=virtio-net-pci"
    ];

    # qemu runs on the host, so it is built for the host. The default in `qemu.nix` is the
    # guest's, which is right for a test - where the two are the same by construction - and
    # wrong here, where the point is to run someone else's machine on this one.
    virtualisation.qemu.package = lib.mkDefault hostPkgs.qemu;

    virtualisation.memorySize = lib.mkDefault 2048;
    virtualisation.cores = lib.mkDefault 2;

    system.build.vm =
      hostPkgs.runCommand "finix-vm-${name}"
        {
          preferLocalBuild = true;
          meta.mainProgram = "run-${name}-vm";
        }
        ''
          mkdir -p $out/bin
          ln -s ${config.system.topLevel} $out/system
          ln -s ${lib.getExe runner} $out/bin/run-${name}-vm
        '';
  };
}
