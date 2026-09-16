# a machine with no initrd, on something which is not finit
#
# tests/no-initrd boots finit, and finit is the one implementation which does not use the
# contract's activation script: it has a plugin of its own, and it mounts /proc before that
# plugin runs. So every no-initrd test there was passed while the path the other four take was
# broken - `finix-activate` reads /proc/cmdline to find the system it is meant to activate, and
# with no initrd nothing has mounted /proc. The machine reported "no init= on the kernel command
# line" while having a perfectly correct one.
#
# This is that path: sinit, which is the barest of the five, booting from a disk with no stage 1
# at all. It also prints how long the trunk took, which is not asserted - a machine which is
# slow is not the failure being looked for - but is the only measurement of a no-initrd boot
# anywhere here, and cheap to keep.
{
  name = "no-initrd-sinit";

  nodes.machine =
    {
      config,
      pkgs,
      modules,
      ...
    }:
    {
      imports = [ modules.sinit ];

      boot.initrd.enable = false;
      sinit.enable = true;
      services.mdevd.enable = true;

      # the scaffolding every other sinit test has: a terminal attached to nothing, so a
      # stalled machine still offers a prompt, and getty off because the contract supplies it
      services.getty.enable = false;
      providers.ttys.devices.tty1 = {
        description = "getty on /dev/tty1";
        requires = [ ];
      };

      fileSystems."/" = {
        device = "/dev/vda";
        fsType = "ext4";
      };

      # /proc/uptime at the moment each level is reached: seconds since the kernel started,
      # which is the only clock that means the same thing on every backend.
      providers.services.units = {
        stamp-multi-user = {
          description = "stamp when multi-user is reached";
          requires = [ "multi-user" ];
          type.oneshot.command = pkgs.writeShellScript "stamp-mu" ''
            ${pkgs.coreutils}/bin/mkdir -p /run/timing
            ${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime > /run/timing/multi-user
          '';
        };

        stamp-running = {
          description = "stamp when the trunk is done";
          requires = [ "running" ];
          type.oneshot.command = pkgs.writeShellScript "stamp-running" ''
            ${pkgs.coreutils}/bin/mkdir -p /run/timing
            ${pkgs.coreutils}/bin/cut -d' ' -f1 /proc/uptime > /run/timing/running
          '';
        };
      };

      virtualisation.qemu.rootImage =
        let
          image = pkgs.callPackage "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
            storePaths = [ config.system.topLevel ];
            volumeLabel = "finix-root";
            populateImageCommands = ''
              mkdir -p ./files/{dev,proc,run,sys,tmp,var,etc,mnt}
              chmod 1777 ./files/tmp
            '';
          };
        in
        pkgs.runCommand "finix-root-sinit.img" { nativeBuildInputs = [ pkgs.e2fsprogs ]; } ''
          cp ${image} $out
          chmod +w $out
          truncate -s +512M $out
          e2fsck -fp $out || true
          resize2fs $out
        '';
    };

  testScript = ''
    machine.start()
    machine.wait_until_succeeds("test -e /run/timing/running", timeout=300)

    with subtest("activation found the system with no initrd to mount /proc for it"):
        # the failure this guards is not a missing file, it is a machine which says its kernel
        # command line has no init= when it does - because /proc/cmdline could not be read
        machine.succeed("grep -q 'root=/dev/vda' /proc/cmdline")
        machine.succeed("test -L /run/current-system")

    with subtest("and the trunk completed"):
        machine.succeed("test -e /run/timing/multi-user")

    mu = machine.succeed("cat /run/timing/multi-user").strip()
    run = machine.succeed("cat /run/timing/running").strip()
    print(f"TIMING sinit, no initrd: multi-user at {mu}s, trunk top at {run}s since kernel start")

    machine.shutdown()
  '';
}
