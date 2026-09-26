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
  cfg = config.virtualisation;

  hostPkgs = cfg.host.pkgs;

  # Whether a mount names storage a virtual machine does not have: a block device, or a
  # filesystem label - anything findable only on the machine the configuration was written for.
  # Everything else is a pseudo-filesystem, a bind, or a share, and works here unchanged.
  namesADisk = fs: fs.label != null || (fs.device != null && lib.hasPrefix "/dev/" fs.device);

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
    # The machine's mounts, with the ones that name a disk backed by a tmpfs where they stood,
    # and everything else left exactly as the machine declared it.
    #
    # Removing them outright was the first thing tried, and it does not work: a mount which is
    # `neededForBoot` and then is simply not there does not fail, it waits. The macbook spent a
    # hundred and twenty seconds in stage 1 on precisely that - preservation waiting for
    # /persistent, giving up with a warning, and then running the rest of the boot with every
    # preserved path missing. Standing in for the mount costs nothing and keeps the shape of the
    # machine, which is the thing under test.
    #
    # Only the disks, though. A pseudo-filesystem is not a thing a virtual machine lacks:
    # `/proc/sys/fs/binfmt_misc` has to stay binfmt_misc or the registrations written to it fail,
    # and a bind mount or a 9p share is as valid here as anywhere. Turning those into tmpfs was
    # the second thing tried, and it is how that was found out.
    #
    # The stand-ins are volatile, which is the point: every boot starts from an empty
    # /persistent, so what a service does on a machine it has never run on before is what gets
    # exercised.
    virtualisation.fileSystems = lib.mkMerge [
      (lib.mapAttrs
        (
          _: fs:
          if namesADisk fs then
            {
              device = "tmpfs";
              fsType = "tmpfs";
              inherit (fs) neededForBoot;

              # X-mount.mkdir because the root is a fresh tmpfs: every one of these mount points
              # has to be created before anything can be mounted on it, and `mount -a` will not
              # do that by itself. This is util-linux' own option, not a systemd one. Without it
              # the first stand-in fails, `mount-filesystems` fails with it, and the trunk stops
              # there - which is how this was found, on /boot.
              #
              # The machine's own options are not carried across: they describe the filesystem it
              # named - a btrfs subvolume, a vfat umask - and none of that means anything to a
              # tmpfs.
              options = [
                "mode=755"
                "X-mount.mkdir"
              ];
            }
          else
            fs
        )
        (
          lib.filterAttrs (
            mountPoint: _:
            # The root is replaced below whatever it was, so it is not up for pass-through here -
            # a machine whose root is already a tmpfs would otherwise define it twice and
            # conflict.
            #
            # And /nix with it, because the store arrives here by its own route and a machine's
            # /nix names a disk this machine does not have. What that costs is /nix/var, which
            # the dropped mount is what makes persistent: it lands on the volatile root instead,
            # so the nix database starts empty every boot. `nix-register-closure` above is why
            # that is survivable.
            mountPoint != "/" && !(lib.hasPrefix "/nix" mountPoint)
          ) cfg.hostFileSystems
        )
      )

      {
        "/" = {
          device = "tmpfs";
          fsType = "tmpfs";
          options = [ "mode=755" ];
        };
      }
    ];

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

    # Syslog to the console, where a machine sends it to files.
    #
    # Without this the boot log stops the moment syslogd starts: finit logs to /dev/log from
    # then on, syslogd writes that to /var/log, and the console shows nothing more. Which reads
    # exactly like a hung boot and is not one - three separate stalls were diagnosed through
    # this window before it was closed, and each time the evidence was on a filesystem that
    # only existed inside the machine that would not finish booting.
    #
    # The kernel is already talking to this console, so joining it there is not a new kind of
    # noise. The test harness does the same thing for the same reason.
    environment.etc."syslog.conf" = lib.mkIf config.services.sysklogd.enable (
      lib.mkVMOverride {
        text = ''
          *.* /dev/console

          include /etc/syslog.d/*.conf
        '';
      }
    );

    # A writable store, by stacking an overlay over the read-only one.
    #
    # The host's store arrives as a 9p mount and is bound to /nix/store, and a bind of a
    # read-only filesystem is read-only. Enough to boot - stage 1 only reads the closure - but
    # the first thing wanting to write a store path fails:
    #
    #   error: opening lock file "/nix/store/...-env-manifest.nix.lock": Read-only file system
    #
    # from home-manager's `installPackages`, which builds a profile and cannot.
    #
    # Mounted by a unit rather than declared as a filesystem, for two reasons. overlayfs wants
    # its upper and work directories to exist already, as siblings on one filesystem, and there
    # is no pre-mount hook - as a `neededForBoot` filesystem this would mount in stage 1, before
    # anything had created them, whereas by the second stage `tmpfiles-setup` has. And it has to
    # come after `mount-filesystems`, because that mounts /nix/store from fstab again: an overlay
    # stacked before it is simply shadowed by the bind that lands on top, which looks exactly
    # like an overlay that failed to mount.
    #
    # The upper layer is on the root, a tmpfs here, so what the machine writes to its store
    # lasts as long as the machine - the right lifetime for something discarded after a boot.
    providers.services.tmpfiles.rules = [
      {
        path = "/nix/.rw-store";
        type.directory.mode = "0755";
      }
      {
        path = "/nix/.rw-store/upper";
        type.directory.mode = "0755";
      }
      {
        path = "/nix/.rw-store/work";
        type.directory.mode = "0755";
      }
    ];

    providers.services.units.nix-store-writable = {
      description = "overlay a writable layer over the store";

      requires = [
        (lib.head config.providers.services.trunk.levels)
        "tmpfiles-setup"
        "mount-filesystems"
      ];

      type.oneshot.command = toString (
        pkgs.writeShellScript "nix-store-writable" ''
          ${lib.getExe' pkgs.util-linux "mount"} -t overlay overlay \
            -o lowerdir=/nix/.ro-store,upperdir=/nix/.rw-store/upper,workdir=/nix/.rw-store/work \
            /nix/store
        ''
      );
    };

    # The guest's nix database, which is otherwise empty.
    #
    # A machine's /nix is a real filesystem and a VM cannot have that one, so the mount is
    # dropped below and /nix/var lands on the volatile root - which means the database is
    # recreated, empty, on every boot. The store's *files* are all there over 9p; nix just has
    # no record of any of them, so every path is invalid and nothing can be built, substituted
    # or set as a profile. `nix-env -q` fails, and anything built on it - home-manager
    # activation, most obviously - fails with it.
    #
    # And it fails in a way that reads as something else entirely:
    #
    #   don't know how to build these paths:
    #     /nix/store/...-home-manager-generation
    #   error: path '...' is required, but there is no substituter that can build it
    #
    # which sounds like a missing path or a read-only store, and is neither. `nix path-info
    # --all` in such a machine returns nothing at all.
    #
    # So the closure is registered, the way nixos' own VMs do it. `NIX_REMOTE=` because this
    # writes the database directly rather than asking a daemon to - there is no daemon yet, and
    # the point is that it is running before one needs the answer.
    providers.services.units.nix-register-closure = {
      description = "register the system closure in the nix database";

      # `tmpfiles-setup` makes /nix/var and the directories under it, and this writes into
      # them. Both are in the head tier, and a tier starts together, so the edge is named.
      requires = [
        (lib.head config.providers.services.trunk.levels)
        "tmpfiles-setup"
        "nix-store-writable"
      ];

      type.oneshot.command = toString (
        pkgs.writeShellScript "nix-register-closure" ''
          # Only when there is nothing there: a machine whose /nix/var does persist has this
          # already, and re-registering a whole system closure is not free.
          if [ -s /nix/var/nix/db/db.sqlite ]; then
            exit 0
          fi

          # The path comes off the kernel command line rather than being written into this
          # script, because this script is part of the closure being registered. Naming the
          # registration here would make the closure depend on a path derived from the closure,
          # which is an evaluation that does not terminate.
          reg=$(${lib.getExe' pkgs.gnused "sed"} -n 's/.*regInfo=\([^ ]*\).*/\1/p' /proc/cmdline)

          if [ -z "$reg" ] || [ ! -e "$reg" ]; then
            echo "nix-register-closure: no regInfo= on the kernel command line" >&2
            exit 0
          fi

          # NIX_REMOTE= to write the database directly instead of asking a daemon to: there is
          # no daemon yet, and the point is to be finished before anything needs one.
          NIX_REMOTE= ${lib.getExe' pkgs.nix "nix-store"} --load-db < "$reg"
        ''
      );
    };

    # The registration itself, named where it cannot become part of what it registers.
    virtualisation.qemu.kernelParams = [
      "regInfo=${pkgs.closureInfo { rootPaths = [ config.system.topLevel ]; }}/registration"
    ];

    # Nothing may ask nix anything before the database says the store exists.
    providers.services.units.nix-daemon.requires = [ "nix-register-closure" ];

    # A login on the serial console, which is the terminal `run-<host>-vm` is attached to.
    #
    # Without this the runner is write-only. A machine's gettys are on tty1..tty6, the kernel
    # console is the uart, and nothing here generates a terminal from `console=` the way
    # systemd's getty generator does on nixos - so the boot log scrolls past and then stops,
    # because syslogd takes finit's logging once it starts, and there is no way in.
    #
    # `mkDefault`, so a machine's vmVariant can claim the same device for something else - a
    # display manager, or an autologin.
    #
    # Worth knowing: this is the machine's own user database, password hashes included. A
    # virtual machine built from a real configuration is as good as that configuration's
    # credentials, and should be treated the way the machine is.
    providers.ttys.devices.${serial} = lib.mkDefault {
      description = "login on the serial console";
      requires = [ "multi-user" ];
    };

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

    # 2048 is not enough, and the way it fails is worth knowing: nothing reports being short of
    # memory. dbus never becomes ready, `sysinit` never completes, and the machine sits there -
    # which reads as a readiness bug in dbus and is not one. 4096 gets a full desktop
    # configuration past it; a minimal machine would be happy with far less, and `mkDefault` is
    # so that it can say so.
    virtualisation.memorySize = lib.mkDefault 4096;
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
