# end-to-end test for the programs.limine module
#
# `installer` partitions a shared raw disk, formats an ESP on it and installs
# limine. `target` then boots that same disk under OVMF, with nothing handed to
# it on the qemu command line: the kernel, the initrd and the command line all
# come from what limine read off the ESP.
#
# node ip assignments (sorted alphabetically):
#   installer -> 192.168.1.1
#   target    -> 192.168.1.2
let
  # shared between the two machines: the driver gives each its own run
  # directory, and those sit next to one another.
  esp = {
    file = "../esp.img";
    size = "768M";
  };

  machine =
    { pkgs, ... }:
    {
      services.getty.enable = true;
      services.mdevd.enable = true;

      programs.limine.enable = true;

      virtualisation.memorySize = 2048;

      # travels through bootspec into limine.conf. the target is handed no
      # command line by qemu, so seeing this in /proc/cmdline means limine put
      # it there.
      boot.kernelParams = [ "finix.booted-by=limine" ];
      virtualisation.qemu.disks.esp = esp;

      environment.systemPackages = with pkgs; [
        dosfstools
        util-linux
      ];
    };
in
{
  name = "limine-boot";

  nodes.installer = machine;

  nodes.target =
    { ... }:
    {
      imports = [ machine ];

      virtualisation.qemu.bootMode = "uefi";

      # limine only puts the kernel and initrd on the ESP; the store stays on
      # 9p, exactly as it is for a directly booted machine.
      virtualisation.qemu.mountHostNixStore = true;
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.installer.config.system) topLevel;

      installHook = nodes.installer.config.providers.bootloader.installHook;
      profiles = "/nix/var/nix/profiles";
    in
    ''
      installer.start()
      retry(lambda _: "entering runlevel 2" in installer.get_console_log())

      with subtest("the shared disk gets a GPT with an ESP on it"):
          installer.succeed(
              "sfdisk /dev/vda <<'EOF'\n"
              "label: gpt\n"
              "type=uefi, name=ESP\n"
              "EOF"
          )
          installer.succeed("udevadm settle || partx -a /dev/vda || true")
          installer.wait_until_succeeds("test -b /dev/vda1")

          installer.succeed("mkfs.vfat -F 32 -n ESP /dev/vda1")
          installer.succeed("mkdir -p /boot")
          installer.succeed("mount /dev/vda1 /boot")
          installer.succeed("grep -E ' /boot vfat ' /proc/mounts")

      with subtest("limine is installed onto it"):
          installer.succeed("mkdir -p ${profiles}")
          installer.succeed("ln -sfn ${topLevel} ${profiles}/system-1-link")
          installer.succeed("ln -sfn system-1-link ${profiles}/system")

          installer.succeed("${installHook} ${topLevel}")

          # the fallback path the firmware probes when there is no NVRAM entry
          installer.succeed("test -s /boot/efi/boot/BOOTAA64.EFI")
          installer.succeed("test -s /boot/limine/limine.conf")

      with subtest("the ESP is flushed before the machine goes away"):
          installer.succeed("sync")
          installer.succeed("umount /boot")
          installer.shutdown()

      with subtest("the firmware finds limine and limine boots the system"):
          target.start()

          # the driver only starts buffering the console once the guest backdoor
          # connects, so neither wait_for_console_text nor get_console_log can
          # see the firmware or limine. poll for the far end of the boot, and
          # assert on what limine handed the kernel instead.
          retry(lambda _: "entering runlevel 2" in target.get_console_log())


      with subtest("the booted system is the one that was installed"):
          # nothing was handed to this machine on the qemu command line, so
          # everything running here came off the ESP by way of limine
          target.succeed("test -d /sys/firmware/efi")
          target.succeed("grep -q finix.booted-by=limine /proc/cmdline")
          target.succeed("test -e ${topLevel}/init")
          target.succeed("grep -q 'init=${topLevel}/init' /proc/cmdline")

          target.shutdown()
    '';
}
