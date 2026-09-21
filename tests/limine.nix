# test for the programs.limine module
#
# the qemu harness only supports direct kernel boot, so this cannot verify that
# limine boots the result. what it does verify is the install itself, as root,
# against a real FAT filesystem: generation discovery, limine.conf generation,
# the copies onto vfat, idempotence and the pruning of stale files.
{
  name = "limine";

  nodes.machine =
    { pkgs, ... }:
    {
      services.getty.enable = true;
      services.mdevd.enable = true;

      programs.limine.enable = true;

      boot.kernelModules = [ "loop" ];

      # the ESP image is tmpfs-backed, and the kernel alone is ~61M
      virtualisation.memorySize = 2048;

      environment.systemPackages = with pkgs; [
        dosfstools
        util-linux
      ];
    };

  testScript =
    { nodes }:
    let
      inherit (nodes.machine.config.system) topLevel;

      installHook = nodes.machine.config.providers.bootloader.installHook;
      profiles = "/nix/var/nix/profiles";
    in
    ''
      machine.start()
      machine.wait_for_console_text("entering runlevel 2")

      with subtest("a real FAT filesystem is mounted at the ESP"):
          machine.succeed("truncate -s 256M /esp.img")
          machine.succeed("mkfs.vfat -n ESP /esp.img")
          machine.succeed("mkdir -p /boot")
          machine.succeed("mount -o loop /esp.img /boot")
          machine.succeed("grep -E ' /boot vfat ' /proc/mounts")

      with subtest("a system profile generation exists to install"):
          machine.succeed("mkdir -p ${profiles}")
          machine.succeed("ln -sfn ${topLevel} ${profiles}/system-1-link")
          machine.succeed("ln -sfn system-1-link ${profiles}/system")
          machine.succeed("test -f ${topLevel}/boot.json")

      with subtest("the bootloader installs"):
          machine.succeed("${installHook} ${topLevel}")

      with subtest("limine.conf describes the generation"):
          conf = machine.succeed("cat /boot/limine/limine.conf")
          print(conf)

          assert "//Generation 1" in conf, conf
          assert "protocol: linux" in conf
          assert "default_entry: 2" in conf
          assert "init=${topLevel}/init" in conf
          assert "# NixOS boot entries end here" in conf

      with subtest("the kernel and initrd are copied onto the ESP"):
          machine.succeed("test -s /boot/limine/kernels/*-Image")
          machine.succeed("test -s /boot/limine/kernels/*-initrd")

      with subtest("every referenced file carries a blake2b digest"):
          machine.succeed(
              "grep -E '^kernel_path: boot\\(\\):/limine/kernels/.*#[0-9a-f]{128}$'"
              " /boot/limine/limine.conf"
          )

      with subtest("the EFI binary is installed as removable"):
          machine.succeed("test -s /boot/efi/boot/BOOT*.EFI")

      with subtest("a second run changes nothing"):
          before = machine.succeed("sha256sum /boot/limine/limine.conf; stat -c %Y /boot/limine/kernels/*-Image")
          machine.succeed("${installHook} ${topLevel}")
          after = machine.succeed("sha256sum /boot/limine/limine.conf; stat -c %Y /boot/limine/kernels/*-Image")

          assert before == after, f"{before!r} != {after!r}"

      with subtest("stale files are pruned"):
          machine.succeed("touch /boot/limine/junk /boot/limine/kernels/stale")
          machine.succeed("${installHook} ${topLevel}")
          machine.fail("test -e /boot/limine/junk")
          machine.fail("test -e /boot/limine/kernels/stale")

      with subtest("a newer generation is listed first"):
          machine.succeed("ln -sfn ${topLevel} ${profiles}/system-2-link")
          machine.succeed("${installHook} ${topLevel}")

          entries = machine.succeed("grep '^//Generation' /boot/limine/limine.conf")
          assert entries.split() == ["//Generation", "2", "//Generation", "1"], entries

      with subtest("the ESP survives being unmounted"):
          machine.succeed("umount /boot")
          machine.succeed("mount -o loop /esp.img /boot")
          machine.succeed("test -s /boot/limine/limine.conf")

      machine.shutdown()
    '';
}
