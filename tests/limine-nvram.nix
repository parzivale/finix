# test for the NVRAM half of the programs.limine module
#
# `installer` lays down an ESP the firmware can find on its own, via the
# removable fallback path. `target` boots that, and -- now that it has
# efivarfs, which a directly booted machine does not -- installs limine again
# with canTouchEfiVariables set, writing its own Boot#### entry. The fallback
# path is then deleted, so the only way the machine can boot a second time is
# through the entry limine-install wrote itself.
#
# node ip assignments (sorted alphabetically):
#   installer -> 192.168.1.1
#   target    -> 192.168.1.2
let
  esp = {
    file = "../nvram-esp.img";
    size = "768M";
  };

  machine =
    { pkgs, ... }:
    {
      services.getty.enable = true;
      services.mdevd.enable = true;

      programs.limine.enable = true;

      virtualisation.memorySize = 2048;
      virtualisation.qemu.disks.esp = esp;

      # the target runs the installer's system, so the module has to be
      # available there rather than in the target's own configuration
      boot.supportedFilesystems.efivarfs.enable = true;

      boot.kernelParams = [ "finix.booted-by=limine" ];

      environment.systemPackages = with pkgs; [
        dosfstools
        util-linux

        # to check our boot entry with something that is not our own code
        efibootmgr
      ];
    };
in
{
  name = "limine-nvram";

  nodes.installer = machine;

  nodes.target =
    { ... }:
    {
      imports = [ machine ];

      virtualisation.qemu.bootMode = "uefi";
      virtualisation.qemu.mountHostNixStore = true;

      # so this node's install hook registers itself rather than relying on
      # the fallback path
      boot.loader.efi.canTouchEfiVariables = true;
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.installer.config.system) topLevel;

      removable = nodes.installer.config.providers.bootloader.installHook;
      registered = nodes.target.config.providers.bootloader.installHook;

      profile = "ln -sfn ${topLevel} /nix/var/nix/profiles/system-1-link";
    in
    ''
      installer.start()
      retry(lambda _: "entering runlevel 2" in installer.get_console_log())

      with subtest("an ESP the firmware can find without any NVRAM entry"):
          installer.succeed(
              "sfdisk /dev/vda <<'EOF'\n"
              "label: gpt\n"
              "type=uefi, name=ESP\n"
              "EOF"
          )
          installer.wait_until_succeeds("test -b /dev/vda1")
          installer.succeed("mkfs.vfat -F 32 -n ESP /dev/vda1")
          installer.succeed("mkdir -p /boot && mount /dev/vda1 /boot")

          installer.succeed("mkdir -p /nix/var/nix/profiles && ${profile}")
          installer.succeed("${removable} ${topLevel}")

          installer.succeed("test -s /boot/efi/boot/BOOTAA64.EFI")
          installer.succeed("sync && umount /boot")
          installer.shutdown()

      with subtest("the booted system writes its own boot entry"):
          target.start()
          retry(lambda _: "entering runlevel 2" in target.get_console_log())

          # the running system is the installer's, which does not mount this
          target.succeed(
              "mountpoint -q /sys/firmware/efi/efivars"
              " || mount -t efivarfs efivarfs /sys/firmware/efi/efivars"
          )
          target.succeed("mkdir -p /boot && mount /dev/vda1 /boot")
          target.succeed("mkdir -p /nix/var/nix/profiles && ${profile}")

          target.succeed("${registered} ${topLevel}")

          # a registered install goes here, not to the fallback path
          target.succeed("test -s /boot/efi/limine/BOOTAA64.EFI")

      with subtest("efibootmgr agrees the entry is well formed"):
          entries = target.succeed("efibootmgr -v")
          print(entries)

          limine = [line for line in entries.splitlines() if "Limine" in line]
          assert len(limine) == 1, entries

          # the partition we installed to, and the loader on it
          assert "HD(1," in limine[0], limine[0]
          assert "\\efi\\limine\\BOOTAA64.EFI" in limine[0], limine[0]

          # and it has to be in the boot order, or the firmware will not try it
          order = [line for line in entries.splitlines() if line.startswith("BootOrder:")]
          entry_id = limine[0].split()[0].removeprefix("Boot").rstrip("*")
          assert entry_id in order[0], f"{entry_id} not in {order[0]}"

      with subtest("with the fallback path gone, only that entry can boot it"):
          target.succeed("rm -r /boot/efi/boot")
          target.fail("test -e /boot/efi/boot/BOOTAA64.EFI")

          target.succeed("sync && umount /boot")
          target.shutdown()

          target.start()
          retry(lambda _: "entering runlevel 2" in target.get_console_log())

          target.succeed("grep -q finix.booted-by=limine /proc/cmdline")
          target.shutdown()
    '';
}
