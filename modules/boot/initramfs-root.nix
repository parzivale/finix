# the initramfs as the root, rather than as a stage on the way to one
#
# In this mode there is no handover: the kernel's rootfs - a tmpfs, which
# is where an initramfs is unpacked - is the root the machine keeps. `/init` is this script,
# and all it does is the one thing that has to happen before any init can read its own
# configuration: mount the filesystems the store is on, so that the paths in that configuration
# resolve.
#
# That ordering is the whole reason the stage exists. Every implementation of
# `providers.services` is PID 1 reading a configuration whose every command is a store path,
# and `providers.services.activationScript` is already the contract's answer to "what must
# happen before that" - it mounts /proc, finds the closure from init= on the command line, runs
# its activate script, and leaves /etc behind for the init to read. What it cannot do is mount
# the store it is reading all of that from, because it is itself a store path. Hence a script
# in the initramfs, which is not.
#
# Deliberately not a stage. It waits for nothing, opens nothing, assembles nothing - a machine
# needing any of that wants the `stage` mode, which is the default and is untouched by this.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.boot.initrd;

  # everything that has to be there before the init runs, which is what `neededForBoot` means -
  # except `/` itself, which is the rootfs and is already mounted by the time anything here
  # runs.
  early = lib.filter (fs: fs.neededForBoot && fs.mountPoint != "/") (
    lib.attrValues config.fileSystems
  );

  # shallowest first, so /nix is mounted before anything under it. Depth then name, rather than
  # the `depends` graph the contract's own mount units use: this runs before any of that exists,
  # and a path cannot be mounted over a parent which is not there yet.
  ordered = lib.sort (
    a: b:
    let
      depth = p: lib.length (lib.splitString "/" p);
    in
    if depth a.mountPoint != depth b.mountPoint then
      depth a.mountPoint < depth b.mountPoint
    else
      a.mountPoint < b.mountPoint
  ) early;

  # one attempt at the whole set. Called again on failure, which is why the mkdir and the
  # already-mounted test are inside it rather than done once above.
  mountAll = lib.concatMapStrings (
    fs:
    let
      opts = lib.concatStringsSep "," (fs.options or [ ]);
    in
    ''
      ${lib.getExe' pkgs.coreutils "mkdir"} -p ${fs.mountPoint}
      if ! ${pkgs.util-linux}/bin/findmnt -rno TARGET ${fs.mountPoint} >/dev/null 2>&1; then
        ${pkgs.util-linux.mount}/bin/mount -t ${fs.fsType} ${
          lib.optionalString (opts != "") "-o ${lib.escapeShellArg opts} "
        }${fs.device} ${fs.mountPoint} 2>/dev/null || {
          missing="$missing ${fs.mountPoint}"
          fail=1
        }
      fi
    ''
  ) ordered;

  init = pkgs.writeShellScript "initramfs-root-init" ''
    # the mount points first. An initramfs contains what was put in it and nothing else - there
    # is no /proc, /sys, /dev or /run directory in the image unless something asks for one, and
    # `mount` on a path that does not exist fails with the same ENOENT as a missing device.
    #
    # Which is worth being concrete about, because of how it presents: with no /proc there is no
    # /proc/cmdline, and activation reads the closure's location from there -
    #
    #   finix-activate: no init= on the kernel command line, cannot find the system
    #
    # from a machine whose command line was perfectly correct and did carry init=.
    ${lib.getExe' pkgs.coreutils "mkdir"} -p /proc /sys /dev /run /etc /tmp

    [ -e /proc/cmdline ] || ${pkgs.util-linux.mount}/bin/mount -t proc -o nosuid,nodev,noexec proc /proc
    [ -e /sys/kernel ] || ${pkgs.util-linux.mount}/bin/mount -t sysfs -o nosuid,nodev,noexec sys /sys

    # /dev, which nothing else is going to do here.
    #
    # `CONFIG_DEVTMPFS_MOUNT=y` sounds like it covers this and does not: the kernel mounts
    # devtmpfs for a root it mounted itself, and an initramfs root is handed over before that.
    # It would have nowhere to go either way, the image having no /dev to mount onto.
    #
    # Nothing noticed while the only filesystems tested were tmpfs and overlay, which name no
    # device at all. A real root is `/dev/nvme0n1p5` or similar, and without this that path is
    # simply absent.
    [ -e /dev/null ] || ${pkgs.util-linux.mount}/bin/mount -t devtmpfs -o nosuid devtmpfs /dev

    # every module that might be needed to reach the root, which is what `availableKernelModules`
    # means - stage one loads that set by running udev and coldplugging, and there is no udev
    # here.
    #
    # The whole set rather than a list per machine: `kernelModules` alone is the modules a
    # configuration asks for by name, which on a machine whose store is on NVMe is `btrfs` and
    # `dm_mod` - the filesystem but not the controller under it. The driver chain that makes
    # /dev/nvme0n1p5 exist (nvme-apple, pcie-apple, apple-dart, apple-sart on Apple silicon) is
    # in `availableKernelModules`, and it is there precisely because it is not knowable from the
    # configuration which of them a given machine needs.
    #
    # Ordering is not expressed and does not need to be. A platform driver whose parent is not
    # bound yet returns -EPROBE_DEFER and the kernel retries it once the parent appears, which is
    # the mechanism a modprobe list could not reproduce anyway.
    #
    # `|| :` because most of these will not apply: a module built in rather than built as one, or
    # for hardware this machine does not have, is not an error.
    ${lib.concatMapStrings (m: ''
      ${pkgs.kmod}/bin/modprobe ${m} 2>/dev/null || :
    '') (lib.unique (config.boot.initrd.kernelModules ++ config.boot.initrd.availableKernelModules))}

    # then mount, retrying, because loading a driver is not the same as having the device.
    #
    # PCIe enumeration and an NVMe controller's probe are asynchronous, and deferred probe means
    # a driver may bind several rounds after the modprobe that loaded it returned. So the first
    # attempt can fail on a machine where nothing is wrong, which is what the stage this replaces
    # spent its `wait-dev-*` units on.
    #
    # Bounded, and the bound is the honest part: unmounted after this long is a machine that is
    # not going to boot, and saying so beats a hang with no output.
    # a shell, rather than a reboot, when there is nothing else to be done.
    #
    # Reaching this means the machine cannot boot, and rebooting to the same entry means it
    # cannot boot again - a loop with a ten-second window to read the reason in. A shell is the
    # one thing that turns that into something diagnosable from the machine itself: the store may
    # well be mounted, so its whole closure is there to look with.
    #
    # It is also the only way this mode reports anything at all. There is no log: syslog is a
    # unit, units are the init's, and the init is what did not start - so /var/log has nothing
    # from a boot which failed here, and cannot have.
    rescue() {
      echo "" >&2
      echo "initramfs-root: $1" >&2
      echo "initramfs-root: ${config.boot.init} was not started. dropping to a shell." >&2
      # whether the store is actually usable, not whether a directory called /nix/store exists.
      #
      # `[ -d /nix/store ]` was the first version of this and it lied: /init mkdirs the mount
      # points, so the directory is there whether or not anything was mounted onto it. A VM built
      # without the host store shared reported "the store is mounted" over an empty one, which is
      # the opposite of what a rescue message is for. The activation script is the thing that has
      # to be reachable, so ask about that.
      if [ -x ${config.providers.services.activationScript} ]; then
        echo "initramfs-root: the store is mounted and reachable." >&2
      else
        echo "initramfs-root: the store is NOT usable - /nix/store has $(${lib.getExe' pkgs.coreutils "ls"} /nix/store 2>/dev/null | ${lib.getExe' pkgs.coreutils "wc"} -l) entries." >&2
      fi
      echo "" >&2
      exec ${lib.getExe pkgs.bashNonInteractive} -i
    }

    deadline=$(( $(${lib.getExe' pkgs.coreutils "date"} +%s) + 30 ))

    while :; do
      fail=0
      missing=
      ${mountAll}

      [ "$fail" -eq 0 ] && break

      if [ "$(${lib.getExe' pkgs.coreutils "date"} +%s)" -ge "$deadline" ]; then
        rescue "after 30s, still not mounted:$missing - the device may need a module which is not in boot.initrd.availableKernelModules"
      fi

      ${lib.getExe' pkgs.coreutils "sleep"} 0.2
    done

    # activation, here rather than in whatever this execs.
    #
    # This is the contract's own requirement - "an implementation which is PID 1 must run this
    # before reading its own configuration, because its configuration is one of the things
    # activation puts in /etc" - and in this mode `/init` is the only thing that can honour it.
    # A backend cannot: finit checks for /etc/fstab before its own plugins run, so it reaches
    # sulogin before it has had a chance to create the /etc it is looking in, and the backends
    # which run the script explicitly do so from a configuration they have already read.
    #
    # Doing it here is also what makes the mode backend-neutral. The script finds the closure
    # from init= on the kernel command line, which is still there - the kernel ignored it in
    # favour of this script but left it in /proc/cmdline - so nothing about which init comes
    # next enters into it.
    #
    # Backends that also run it will run it twice. That is redundant rather than wrong: an
    # activation script is idempotent, and the symlinks it places are `ln -sfn`.
    #
    # Its status is checked, which it was not. Activation failing leaves no /etc, so the init
    # then starts with no configuration to read - and finit's account of that is a complaint
    # about /etc/fstab, which sends whoever reads it looking at filesystems rather than at the
    # script which was supposed to write the file. An activation script reports a non-zero status
    # if any of its snippets failed, so this is deliberately loud rather than fatal on its own:
    # `activate` carries on past a failed snippet, and some of what it does is not needed to
    # reach a shell.
    if ! ${config.providers.services.activationScript}; then
      rescue "activation reported failure - see the snippet names above"
    fi

    # execed, not run: this is PID 1, and whatever it hands over to has to stay PID 1. The
    # command line still carries init=, which the kernel ignored in favour of this script but
    # left in /proc/cmdline - which is where `activationScript` looks for the closure, so it
    # finds it without anything here having to say.
    exec ${config.boot.init}
  '';
in
{
  config = lib.mkIf (cfg.role == "root") {
    # `/init` is the script, and the packages it names have to be in the image for it to run.
    # makeInitrdNG copies a closure for whatever is in `boot.initrd.path`, and copies a single
    # file for a source given a target - so the script arrives on its own, and its interpreter
    # and every command it calls have to arrive by the other route. Without that:
    #
    #   [    0.249937] Failed to execute /init (error -2)
    #
    # which the kernel reports as the init failing rather than as a missing shebang, and looks
    # identical to `/init` not being there at all. finit never had this as `/init`, being an ELF
    # whose libraries come with it.
    #
    # busybox, util-linux and kmod are already in the default path; bash and coreutils are what
    # this adds, being what the script itself is written in.
    boot.initrd.path = [
      # `bashNonInteractive`, not `pkgs.bash`: that resolves to bash-interactive here, a different
      # derivation at a different store path from the one `writeShellScript` puts in the
      # shebang - so the image had a bash and the script still named one that was not there.
      pkgs.bashNonInteractive
      pkgs.coreutils
    ];

    boot.initrd.contents = [
      {
        target = "/init";
        source = init;
      }
    ];

    assertions = [
      {
        assertion = early != [ ];
        message = ''
          boot.initrd.enable is false and fileSystems."/" is a ${config.fileSystems."/".fsType}, so the initramfs is the root - but no filesystem other than / is marked
          neededForBoot, so /init has nothing to mount and ${config.boot.init} will not be there
          to exec.

          Either mark the filesystem holding /nix as neededForBoot, or set
          boot.initrd.enable = true so that a stage mounts the root and hands over to it.
        '';
      }
    ];
  };
}
