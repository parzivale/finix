# the same machine, with a root the kernel has to be rebuilt to reach
#
# tests/no-initrd boots ext4 on virtio, which the stock kernel already handles - so it proves
# the boot path and nothing about `boot.kernel.builtinFilesystems`. This one's root is btrfs,
# which is a module in the kernel nixpkgs builds, so the derived default has to turn into a
# kernel which actually boots. That is the half where a wrong Kconfig symbol hides: it fails
# at build time, or worse at mount time, and no amount of evaluating options would say so.
{
  name = "no-initrd-btrfs";

  nodes.machine =
    { config, pkgs, ... }:
    {
      boot.initrd.enable = false;

      finit.enable = true;
      services.mdevd.enable = true;
      services.getty.enable = true;

      # btrfs rather than ext4, which is the whole point: builtinFilesystems derives [ "btrfs" ]
      # and the kernel is built with BTRFS_FS=y
      fileSystems."/" = {
        device = "/dev/vda";
        fsType = "btrfs";
      };

      virtualisation.qemu.rootImage =
        let
          closure = pkgs.closureInfo { rootPaths = [ config.system.topLevel ]; };
        in
        pkgs.runCommand "finix-root-btrfs.img"
          {
            nativeBuildInputs = [
              pkgs.btrfs-progs
              pkgs.coreutils
            ];
          }
          ''
            mkdir -p root/nix/store root/{dev,proc,run,sys,tmp,var,etc,mnt}
            chmod 1777 root/tmp
            xargs -I % cp -a --reflink=auto % -t root/nix/store/ < ${closure}/store-paths
            cp ${closure}/registration root/nix-path-registration

            truncate -s 3G $out
            mkfs.btrfs -L finix-root --rootdir root $out
          '';
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e /etc/passwd", timeout=300)

    with subtest("the kernel mounted a btrfs root with no initrd"):
        machine.succeed("grep -q 'rootfstype=btrfs' /proc/cmdline")
        machine.succeed("grep -qE '^/dev/root / btrfs rw' /proc/mounts")

    with subtest("btrfs is built in rather than loaded"):
        # a module would have had to come from the root it is mounting, which is the thing an
        # initrd exists to solve. Built in, it is in the kernel's own list and not in lsmod.
        machine.succeed("grep -qw btrfs /proc/filesystems")
        machine.fail("grep -qw '^btrfs' /proc/modules")

    with subtest("and the machine came up on it"):
        machine.succeed("test -x /run/current-system/sw/bin/stty")
        machine.succeed("grep -qE '^tmpfs /run tmpfs' /proc/mounts")

    machine.shutdown()
  '';
}
