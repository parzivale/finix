# a tmpfs root with a stage 1 in front of it - which is what macbook actually is, and what
# nothing covered
#
# tests/no-initrd-tmpfs is this disk layout with no initrd, so finix-init builds the root
# itself. Every other test has a root the kernel or a stage mounts conventionally. The
# combination here - a declared tmpfs root *and* a stage 1 that has already built it - was the
# one shape with no test, and it is the shape of the only machine running this.
#
# What it is really testing is that finix-init does nothing. `root` is non-null, because `/` is
# declared a tmpfs, so the pivot is reached and has to decline: stage 1 built that root and
# switch_root'ed into it, the store is already mounted under it, and pivoting again would throw
# all of that away. `is_tmpfs("/")` is the guard that declines, and until this test it was
# guarding a path nothing exercised.
#
# The cost of the guard being wrong is total and silent, which is why this waits on console text
# rather than a unit. finix-init runs before activation, before the init, and so before anything
# that logs - a boot which dies here leaves nothing in /var/log at all, on the machine or in
# this VM, and the only evidence is what reached the console.
{
  name = "initrd-tmpfs";

  nodes.machine =
    { config, pkgs, ... }:
    {
      # the initrd is the point: on, and so stage 1 builds the root before finix-init runs
      boot.initrd.enable = true;

      finit.enable = true;
      services.mdevd.enable = true;
      services.getty.enable = true;

      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
        options = [
          "size=2G"
          "mode=755"
        ];
      };

      # the store on its own subvolume, mounted by stage 1 rather than by the kernel
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
        pkgs.runCommand "finix-store-btrfs-initrd.img"
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
            mkfs.btrfs -L finix-store --rootdir root --subvol rw:nix $out
          '';
    };

  testScript = ''
    machine.start()

    with subtest("stage 1 runs and hands over"):
        machine.wait_for_console_text("finix - stage 1")
        machine.wait_for_console_text("finix - stage 2")

    with subtest("finix-init declined to pivot"):
        # the assertion is the wording. "/ is not the declared tmpfs; pivoting" is what it says
        # when the guard does not fire, and on this path that is the bug rather than the feature:
        # stage 1 has already built the root and mounted the store under it, and a pivot here
        # replaces that with an empty tmpfs and detaches what the store was on. There is no
        # recovering from it - the binary cannot reach its own closure to run activation, cannot
        # exec the init, and `rescue` cannot find a shell, so it sleeps. A crawl, and then
        # nothing, for ever.
        #
        # Asserted by what comes after rather than by the absence of that line, the console
        # being a stream and not a file: reaching a runlevel at all means the store survived.
        machine.wait_for_console_text("entering runlevel 2")

    machine.wait_until_succeeds("test -e /etc/passwd", timeout=300)

    with subtest("the root is the declared tmpfs, built by the stage"):
        machine.succeed("grep -qE '^(none|tmpfs) / tmpfs ' /proc/mounts")
        machine.succeed("findmnt -no FSTYPE / | grep -qx tmpfs")

    with subtest("and the store is where it was mounted, once"):
        machine.succeed("grep -qE '^/dev/vda /nix btrfs .*subvol=/nix' /proc/mounts")
        machine.succeed("test -d /nix/store")
        # one mount of the device, not a pivot's leftovers beside it
        machine.succeed("test $(grep -c '^/dev/vda ' /proc/mounts) -eq 1")
        machine.fail("test -e /.old-root")
        machine.fail("test -e /.finix-root")

    with subtest("the generation is the one the bootspec named"):
        machine.succeed("readlink /run/current-system | grep -qE '^/nix/store/'")
        machine.fail("readlink /run/current-system | grep -q '/nix/nix/'")

    with subtest("and activation had what it needed"):
        machine.succeed("grep -qE '^/nix/store/.*modprobe$' /proc/sys/kernel/modprobe")

    machine.shutdown()
  '';
}
