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

  # what the kernel is handed as root=, which is not always what the machine wrote down.
  #
  # root= is parsed before any userspace exists, by early_lookup_bdev in block/early-lookup.c,
  # and what it understands is a device node, a major:minor pair, PARTUUID= and PARTLABEL= -
  # the last two read straight out of the partition table. Everything else is a symlink under
  # /dev/disk, and those are made by udev or mdevd once they are running, which with no initrd
  # is long after this. A machine which says /dev/disk/by-uuid/... is handing the kernel a path
  # that does not exist yet, and what comes back is "Cannot open root device ... or
  # unknown-block(0,0)": a machine which appears to have no disk, from a configuration which
  # named its root perfectly well.
  #
  # Two of those forms are the partition table's own, so they are translated rather than
  # refused. The rest are the filesystem's, which means reading the filesystem to find out
  # where it is, which is exactly the work an initrd exists to do.
  byDiskPrefixes = {
    "/dev/disk/by-partuuid/" = "PARTUUID=";
    "/dev/disk/by-partlabel/" = "PARTLABEL=";
  };

  translate =
    d:
    let
      hit = lib.filter (p: lib.hasPrefix p d) (lib.attrNames byDiskPrefixes);
    in
    if hit == [ ] then d else byDiskPrefixes.${lib.head hit} + lib.removePrefix (lib.head hit) d;

  # the ones nothing here can translate: a filesystem label or uuid, or a link made from what
  # the hardware says about itself
  needsUserspace =
    d:
    d != null
    && lib.any (p: lib.hasPrefix p d) [
      "/dev/disk/by-uuid/"
      "/dev/disk/by-label/"
      "/dev/disk/by-id/"
      "/dev/disk/by-path/"
      "/dev/disk/by-diskseq/"
    ];

  # other names for the same device, so that what a machine wrote down and what the kernel can
  # use need not be the same thing.
  #
  # Every group here is one device under all the names it answers to. Given one, this finds the
  # rest - so a root written as /dev/disk/by-uuid/... becomes the PARTUUID or the device node
  # beside it in the same group, which is a thing the kernel resolves on its own.
  #
  # Where the groups come from is not this module's business. nixos-facter reports them: every
  # entry under `hardware.disk` carries a `unix_device_names` listing exactly this, which is
  # one line to wire up:
  #
  #     boot.deviceAliases = map (d: d.unix_device_names or [ ])
  #       (config.facter.report.hardware.disk or [ ]);
  #
  # and a machine without a report can write the group out by hand, or say nothing and name its
  # root the way the kernel wants.
  aliasesFor =
    d:
    let
      group = lib.filter (names: lib.elem d names) config.boot.deviceAliases;
    in
    lib.unique (lib.concatLists group);

  # what the kernel can resolve before userspace exists: a device node which is not one of
  # udev's symlinks, and the two partition-table forms.
  kernelResolvable =
    d:
    lib.hasPrefix "PARTUUID=" d
    || lib.hasPrefix "PARTLABEL=" d
    || (lib.hasPrefix "/dev/" d && !(lib.hasPrefix "/dev/disk/by-" d))
    || lib.any (p: lib.hasPrefix p d) (lib.attrNames byDiskPrefixes);

  # PARTUUID first: it is the partition's own name, and survives the disk being renamed or
  # reordered, which a device node does not. The node is the fallback because it is what a
  # machine which was given no aliases would have had to say itself.
  preferred =
    candidates:
    let
      partition = lib.filter (
        d: lib.hasPrefix "/dev/disk/by-part" d || lib.hasPrefix "PART" d
      ) candidates;
      nodes = lib.filter (d: lib.hasPrefix "/dev/" d && !(lib.hasPrefix "/dev/disk/" d)) candidates;
      usable = partition ++ nodes;
    in
    if usable == [ ] then null else lib.head usable;

  # what the root is finally called: what it says, if the kernel can use it; otherwise whatever
  # else the same device is known by.
  resolved =
    if root == null || root.device == null then
      null
    else if kernelResolvable root.device then
      translate root.device
    else
      let
        other = preferred (lib.filter (d: d != root.device) (aliasesFor root.device));
      in
      if other == null then null else translate other;

  device = resolved;

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
  options.boot.deviceAliases = lib.mkOption {
    type = with lib.types; listOf (listOf str);
    default = [ ];
    example = lib.literalExpression ''
      map (d: d.unix_device_names or [ ]) (config.facter.report.hardware.disk or [ ])
    '';
    description = ''
      Groups of names which refer to the same block device.

      A machine names its root however it likes - `/dev/disk/by-uuid/...` is what a NixOS
      hardware scan writes, and what most configurations carry. The kernel cannot use that: it
      reads `root=` before any userspace exists, and those paths are symlinks udev or mdevd
      make once they are running. Telling this module which names mean the same device lets it
      hand the kernel one it can resolve, instead of refusing the configuration.

      Each element is one device under all of its names. nixos-facter reports exactly that, as
      `unix_device_names` on each entry under `hardware.disk`:

      ```nix
      boot.deviceAliases = map (d: d.unix_device_names or [ ])
        (config.facter.report.hardware.disk or [ ]);
      ```

      Nothing here depends on facter - a group written by hand does as well, and `lsblk -o
      NAME,PATH,PARTUUID,UUID` is where the names come from either way.

      Only consulted when there is no initrd and the root is named as something the kernel
      cannot resolve. A machine with an initrd resolves its own root in stage 1, as it always
      has.
    '';
  };

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
        assertion = root == null || root.device != null;
        message = ''
          boot.initrd.enable is false, so the root filesystem is named to the kernel as root=
          on the command line, and fileSystems."/" has no device to name it by.

          A label is not enough: the kernel reads root= before any userspace exists, and a
          filesystem label means reading the filesystem to find out where it is.

          Set fileSystems."/".device: /dev/nvme0n1p2, or PARTUUID=<uuid>, or PARTLABEL=<name>.
        '';
      }

      {
        # only when nothing could be resolved: a device named as one of udev's symlinks is
        # fine if something said what else that device is called.
        assertion = root == null || root.device == null || device != null;
        message = ''
          fileSystems."/".device is ${toString root.device}, which is a symlink udev or mdevd
          makes once it is running - and with no initrd, nothing is running when the kernel
          mounts the root.

          What the kernel resolves on its own is a device node, a major:minor pair, and
          PARTUUID= or PARTLABEL=, which it reads out of the partition table. A filesystem uuid
          or label is not among them: finding the filesystem to ask it means having mounted
          something already, which is what an initrd is for.

          Three ways out, in the order they are worth taking:

            - tell this module what else that device is called, in boot.deviceAliases, and it
              will pick one the kernel can use. nixos-facter reports them, or `lsblk -o
              NAME,PATH,PARTUUID,UUID` will tell you.
            - name the partition here instead: PARTUUID=<uuid>, or the device node itself.
            - set boot.initrd.enable = true and keep the uuid, since stage 1 runs the udev
              which makes these paths.
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
