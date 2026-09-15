# reaching the root filesystem without an initrd
#
# With `boot.initrd.enable = false` there is no stage 1: nothing loads a module, waits for a
# device or mounts anything before init runs. The kernel mounts `/` itself from what `root=`
# names on the command line, and execs `boot.init` out of it - so the work stage 1 would have
# done has to be either unnecessary or the kernel's own.
#
# That is a real configuration rather than a degraded one, and on a machine whose root is an
# ordinary partition it is the simpler of the two: an initrd exists to load the drivers needed
# to reach a root the kernel cannot reach unaided, and a kernel with those drivers built in
# needs no help. The stock `pkgs.linuxPackages` builds in ext4, virtio and 9p, among others;
# `boot.kernel.builtinFilesystems` builds in whatever else a particular root needs.
#
# What it cannot do is arrange anything: no LUKS to open, no volume group to import, no pool
# to bring online, and no second filesystem mounted before init. Everything else in
# `fileSystems` is mounted after init starts, by the contract's `mount-filesystems` unit, the
# same as on a machine which does have an initrd. The assertions below are where that line is
# drawn, because each thing on the wrong side of it fails as a machine which boots to nothing.
{
  config,
  lib,
  ...
}:
let
  root = config.fileSystems."/" or null;

  # the kernel takes these as flags of its own rather than as part of `rootflags`, and
  # `defaults` means nothing to it at all
  ownFlags = [
    "defaults"
    "ro"
    "rw"
  ];

  rootflags = lib.filter (opt: !(lib.elem opt ownFlags)) root.options;

  # by label where one is given, since that is what the machine was described by - the kernel
  # resolves LABEL= itself, no different from a device node
  device = if root.label != null then "LABEL=${root.label}" else root.device;

  params = [
    "root=${device}"
  ]
  ++ lib.optional (root.fsType != "auto") "rootfstype=${root.fsType}"
  ++ lib.optional (rootflags != [ ]) "rootflags=${lib.concatStringsSep "," rootflags}"

  # read-write from the first instruction, unless the machine asked for otherwise.
  #
  # The usual arrangement is the opposite - the kernel mounts read-only, the init checks the
  # filesystem and remounts - and it does not survive here, because activation runs before
  # anything else this system does. On finit it is a plugin at PLUGIN_INIT, and what it writes
  # is /etc, so on a read-only root there is no /etc for finit to read its fstab out of and the
  # boot ends in sulogin. There is nothing to remount with before the thing which does the
  # remounting exists.
  ++ [ (if lib.elem "ro" root.options then "ro" else "rw") ];

  # `neededForBoot` means "mounted before stage 2 init", which is a thing only an initrd can
  # do. `/` is the exception the kernel handles itself.
  early = lib.filter (fs: fs.neededForBoot && fs.mountPoint != "/") (
    lib.attrValues config.fileSystems
  );

  # a root the kernel has no way to mount from a command line: a tmpfs has no device to name,
  # and the initrd was what created one and populated it
  virtualRoot =
    root != null
    && lib.elem root.fsType [
      "tmpfs"
      "ramfs"
    ];
in
{
  config = lib.mkIf (!config.boot.initrd.enable) {
    boot.kernelParams = lib.mkIf (root != null && !virtualRoot) params;

    # and never checked at boot, which the fstab has to say out loud.
    #
    # An initrd is where a root gets checked: it is the one moment the filesystem is there and
    # not yet mounted. Here the kernel mounted it read-write before userspace existed, so a
    # `pass` of 1 can only point fsck at a live filesystem, which is not a check - it is a way
    # to lose one. The check belongs somewhere this machine is not running: rescue media, or
    # the initrd this configuration is doing without.
    fileSystems."/".noCheck = lib.mkDefault true;

    # /run has to be a tmpfs before anything writes to it, and with no stage 1 nothing has
    # made it one yet.
    #
    # An initrd mounts /run as part of reaching the root, so by the time an ordinary machine
    # runs activation the tmpfs is already there. Here the first thing to touch /run is
    # activation itself, and what it writes - /run/current-system, a symlink into the store -
    # lands on the root filesystem instead. The tmpfs is then mounted over the top by the init
    # and the file is hidden rather than removed, which makes this invisible until something
    # walks the directory underneath.
    #
    # finit's bootmisc plugin is that something. It cleans stale runtime state over /tmp/,
    # /var/run/ and /var/lock/, skipping any of them which is a tmpfs - it resolves the path
    # first, so /var/run -> /run is recognised as the tmpfs it usually is and left alone. Here
    # it is not one yet, so the clean proceeds, and the walk is nftw() without FTW_PHYS: it
    # follows /run/current-system into /nix/store and removes the contents of the toplevel the
    # machine is running out of. What is left boots to a system missing its own /sw, with
    # `stty: command not found` in a shell and a different set of casualties every time.
    #
    # Mounting it here fixes that at the cause, and costs a machine which already has one
    # nothing: `mountpoint` is asked first, so on a switch - where /run is the tmpfs and is
    # holding the state of a running init - this does nothing at all.
    # /run/lock comes with it, because finit mounts the two together and would otherwise not
    # mount either: its own guard is the same question this one asks - is /run already a
    # mountpoint or a tmpfs - so a /run which is already there means finit skips the whole
    # block, the size cap on /run/lock included. That cap is what stops anything writable by
    # everyone from filling /run, and units here do write there (dbus takes /run/lock/subsys).
    # The other implementations never had it at all, so this gives it to them too.
    system.activation.scripts.runTmpfs = ''
      if ! mountpoint -q /run; then
        mkdir -p /run
        mount -t tmpfs -o mode=0755,nosuid,nodev,noexec,relatime tmpfs /run
      fi

      if ! mountpoint -q /run/lock; then
        mkdir -p /run/lock
        # sticky, unlike finit's own 0777: a directory everything can write to is one where
        # anything could otherwise remove somebody else's lock file
        mount -t tmpfs -o mode=1777,size=5m,nosuid,nodev,noexec,relatime tmpfs /run/lock
      fi
    '';

    # stage 1 would have loaded these before mounting; there is no stage 1, so they are
    # ordinary modules for the running system to load. Whatever the root itself needs is not
    # among them - that has to be built into the kernel, which is the assertion below.
    boot.kernelModules = config.boot.initrd.kernelModules;

    assertions = [
      {
        assertion = root != null;
        message = ''
          boot.initrd.enable is false, so the kernel mounts the root filesystem itself and
          has to be told which one. Declare fileSystems."/".
        '';
      }

      {
        assertion = root == null || root.device != null || root.label != null;
        message = ''
          boot.initrd.enable is false, so the root filesystem is named to the kernel as
          root= on the command line. fileSystems."/" has neither a device nor a label to
          name it by.
        '';
      }

      {
        assertion = root == null || !virtualRoot;
        message = ''
          fileSystems."/" is ${root.fsType}, which the kernel cannot mount as a root: there
          is no device to name and nothing to populate it with. A root of that shape is
          created by an initrd, so this machine needs boot.initrd.enable = true.
        '';
      }

      {
        assertion = early == [ ];
        message = ''
          boot.initrd.enable is false, so nothing runs before the init: ${
            lib.concatMapStringsSep ", " (fs: fs.mountPoint) early
          } ${
            if lib.length early == 1 then "is marked" else "are marked"
          } neededForBoot, and only an initrd can mount a filesystem that early.

          Either put ${
            if lib.length early == 1 then "it" else "them"
          } on the root filesystem, or enable the initrd.
        '';
      }
    ];
  };
}
