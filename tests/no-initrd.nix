# booting with no initrd at all
#
# `boot.initrd.enable = false` is the whole configuration change: there is no stage 1, nothing
# switch-roots, and the kernel mounts the root itself from the `root=` parameters
# modules/boot/root.nix derives from `fileSystems."/"`. What the machine then does is ordinary
# stage 2 - activation, then the init, then the units - which is the point: the initrd is a way
# of reaching a root, not a part of what the system is.
#
# Every other test here boots on a tmpfs root created by stage 1, with the host's store mounted
# over 9p. Neither is available to a machine with no stage 1 - nothing exists to create the
# tmpfs or to mount the store before the init is exec'd out of it - so this one gets a real
# disk holding the closure of its own system, which is what a machine with a root partition
# looks like.
{
  name = "no-initrd";

  nodes.machine =
    { config, pkgs, ... }:
    {
      boot.initrd.enable = false;

      finit.enable = true;
      services.mdevd.enable = true;
      services.getty.enable = true;

      # named to the kernel rather than to a stage 1: root.nix turns this into
      # `root=/dev/vda rootfstype=ext4 rw`
      fileSystems."/" = {
        device = "/dev/vda";
        fsType = "ext4";
      };

      virtualisation.qemu.rootImage =
        let
          # sized to fit its contents exactly, which leaves nowhere for activation to write
          image = pkgs.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
            storePaths = [ config.system.topLevel ];
            volumeLabel = "finix-root";

            # the mount points stage 2 needs on a root which is otherwise nothing but a store.
            # A machine on a tmpfs root gets these from the initrd having made them.
            populateImageCommands = ''
              mkdir -p ./files/{dev,proc,run,sys,tmp,var,etc,mnt}
              chmod 1777 ./files/tmp
            '';
          };
        in
        pkgs.runCommand "finix-root.img" { nativeBuildInputs = [ pkgs.e2fsprogs ]; } ''
          cp ${image} $out
          chmod +w $out

          # room for /etc and everything else activation writes. e2fsck first because
          # resize2fs refuses an image it has not checked.
          truncate -s +512M $out
          e2fsck -fp $out || true
          resize2fs $out
        '';
    };

  testScript = ''
    machine.start()

    # the backdoor is a unit like any other, so a shell here means stage 2 came up - with no
    # stage 1 ever having run
    machine.wait_until_succeeds("test -e /etc/passwd", timeout=240)

    with subtest("the kernel was told where the root is"):
        machine.succeed("grep -q 'root=/dev/vda' /proc/cmdline")
        machine.succeed("grep -q 'rootfstype=ext4' /proc/cmdline")

    with subtest("and mounted it itself"):
        # `/dev/root`, not `/dev/vda`: a root the kernel mounted from `root=` is named that
        # way in /proc/mounts, since it was mounted before any device node existed to name
        machine.succeed("grep -qE '^/dev/root / ext4 rw' /proc/mounts")

    with subtest("nothing was switch-rooted into"):
        # an initrd leaves its own root behind as the mount `switch_root` moved away from; a
        # machine the kernel mounted directly has never had a second root
        machine.fail("test -e /run/current-system/initrd")

    with subtest("the system is running out of the disk, not a store mounted over it"):
        machine.succeed("test -e /run/current-system/init")

        # nothing was brought in from elsewhere: with an initrd the store arrives over 9p and
        # is bind-mounted into place, and here it is simply part of the root filesystem
        machine.fail("grep -q '9p' /proc/mounts")

    with subtest("/run was a tmpfs before anything wrote to it"):
        # the regression this guards is silent and destructive rather than a failed boot.
        #
        # finit cleans stale runtime state over /var/run, skipping it when it resolves to a
        # tmpfs - which it always did, because the initrd mounted one. With no initrd nothing
        # does, and the walk that follows is one which descends through symlinks: /var/run to
        # /run to /run/current-system, into the store, removing the contents of the toplevel
        # the machine is running out of. Mounting it during activation is what restores the
        # precondition, so this asserts the precondition rather than the symptom.
        machine.succeed("grep -qE '^tmpfs /run tmpfs' /proc/mounts")
        machine.succeed("grep -qE '^tmpfs /run/lock tmpfs' /proc/mounts")

        # and the store still holds what the system is running out of
        machine.succeed("test -x /run/current-system/sw/bin/stty")

    with subtest("stage 2 mounted the rest"):
        machine.succeed("grep -q ' /run ' /proc/mounts")

    machine.shutdown()
  '';
}
