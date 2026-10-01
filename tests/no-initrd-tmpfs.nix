# the root the kernel cannot mount: a tmpfs, put in place by the init rather than by a stage
#
# tests/no-initrd and tests/no-initrd-btrfs both hand the kernel the root the machine ends up
# with. This one has none to hand it. `/` is a tmpfs - no device to name and nothing to populate
# it with - so what goes in `root=` is the filesystem holding the *store*, and finix-init pivots
# to the declared tmpfs once it is running. That is the last thing a stage 1 was still needed
# for, and this is the only path on which `pivot_root` runs at all.
#
# The disk is macbook's layout, which is the arrangement that makes this worth testing: the store
# is on a btrfs subvolume, so what the kernel is given is the view *above* it. The top level is
# where /nix/store/... is spelled the way the bootspec spells it, and the bootspec's spelling is
# not negotiable - `init=` is an absolute store path which the kernel resolves before any of this
# runs. Mounting the subvolume itself puts the store at store/..., and the machine panics on an
# init it was handed the correct path to.
{
  name = "no-initrd-tmpfs";

  nodes.machine =
    { config, pkgs, ... }:
    {
      boot.initrd.enable = false;

      finit.enable = true;
      services.mdevd.enable = true;
      services.getty.enable = true;

      # nothing in `root=` can produce this, which is the premise
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "size=2G"
          "mode=755"
        ];
      };

      # the store, on a subvolume with a top level above it to mount in its place.
      #
      # `neededForBoot` is not decoration here: the kernel's mount is scaffolding and is detached
      # once the pivot is done, so this entry is the only thing that puts the store back - which
      # is why root.nix asserts on it rather than letting the machine find out.
      fileSystems."/nix" = {
        device = "/dev/vda";
        fsType = "btrfs";
        options = [ "subvol=nix" ];
        neededForBoot = true;
        noCheck = true;
      };

      virtualisation.qemu.rootImage =
        let
          closure = pkgs.closureInfo { rootPaths = [ config.system.topLevel ]; };
        in
        pkgs.runCommand "finix-store-btrfs.img"
          {
            nativeBuildInputs = [
              pkgs.btrfs-progs
              pkgs.coreutils
            ];
          }
          ''
            mkdir -p root/nix/store
            xargs -I % cp -a --reflink=auto % -t root/nix/store/ < ${closure}/store-paths

            truncate -s 3G $out

            # --subvol is what makes this the layout under test rather than a tree of plain
            # directories: `nix` becomes a subvolume of the top level, so the machine's own
            # `subvol=nix` can mount it and the kernel can mount the level above it.
            mkfs.btrfs -L finix-store --rootdir root --subvol rw:nix $out
          '';
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e /etc/passwd", timeout=300)

    with subtest("the kernel was given the view above the store, not the store's subvolume"):
        # the machine says subvol=nix for /nix and the kernel is handed the same device, so the
        # one thing that must not appear is that option on the command line: `init=` is absolute,
        # and inside the subvolume there is no /nix/store to resolve it against.
        machine.fail("grep -q 'rootflags' /proc/cmdline")
        machine.succeed("grep -q 'rootfstype=btrfs' /proc/cmdline")
        machine.succeed("grep -qE 'init=/nix/store/[^ ]*-finix-system/init' /proc/cmdline")

    with subtest("btrfs is built in, derived from the filesystem the kernel mounts"):
        # and not from fileSystems."/", which is a tmpfs: that answer is not a block filesystem,
        # has no Kconfig symbol, and left the kernel without the filesystem holding its own store.
        machine.succeed("grep -qw btrfs /proc/filesystems")
        machine.fail("grep -qw '^btrfs' /proc/modules")

    with subtest("finix-init pivoted to the declared tmpfs"):
        machine.succeed("grep -qE '^tmpfs / tmpfs ' /proc/mounts")
        machine.succeed("findmnt -no FSTYPE / | grep -qx tmpfs")

    with subtest("and the store is mounted where the machine asked for it"):
        machine.succeed("grep -qE '^/dev/vda /nix btrfs .*subvol=/nix' /proc/mounts")
        machine.succeed("test -d /nix/store")

    with subtest("the scaffolding is gone"):
        # detached rather than left in place: everything mounted before the pivot went with the
        # old root, so leaving it would mean a second /proc under a dot-directory forever.
        machine.fail("test -e /.old-root")
        machine.succeed("test $(grep -c ' /proc proc ' /proc/mounts) -eq 1")

    with subtest("the generation is named by the path the bootspec named"):
        # the regression this replaces: the old root used to be moved to /nix, so the closure was
        # found a second time under that prefix and activation ran out of /nix/nix/store/... -
        # over a mount which was then replaced a step later.
        machine.succeed("readlink /run/current-system | grep -qE '^/nix/store/'")
        machine.fail("readlink /run/current-system | grep -q '/nix/nix/'")

    with subtest("activation had everything it needed"):
        # /proc, specifically. It was mounted before the pivot, went with the old root, and was
        # never put back - so the one activation snippet which writes a sysctl failed, and
        # nothing but the console said so. Asserted by its effect rather than its exit status,
        # that being the half a booted machine can still be asked about.
        machine.succeed("grep -qE '^/nix/store/.*modprobe$' /proc/sys/kernel/modprobe")

    with subtest("and the machine came up on it"):
        machine.succeed("test -x /run/current-system/sw/bin/stty")
        machine.succeed("grep -qE '^tmpfs /run tmpfs' /proc/mounts")

    machine.shutdown()
  '';
}
