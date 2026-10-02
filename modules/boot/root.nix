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

  pathComponents = p: lib.filter (c: c != "") (lib.splitString "/" p);

  # `subvolid=` is not a near miss here: it is longer than the prefix and differs at the
  # character the prefix ends on, so it never matches. Which is the right outcome and the wrong
  # reason to depend on, so the assertion below names it rather than leaving it to that.
  subvolOf =
    fs:
    let
      hit = lib.filter (lib.hasPrefix "subvol=") (fs.options or [ ]);
    in
    if hit == [ ] then null else lib.removePrefix "subvol=" (lib.head hit);

  # which subvolume the kernel is told to mount, which is not the one the machine wrote down.
  #
  # `init=` is an absolute path - /nix/store/...-finix-system/init - and the kernel resolves it
  # against whatever it mounted as `/`. So that mount has to be the view of the device in which
  # the path is spelled the way the bootspec spelled it, and where the store sits on a subvolume
  # of its own that is not the subvolume itself: `subvol=nix` mounted at /nix has the store at
  # `store/`, so /nix/store/... resolves to nothing and the kernel panics on an init it was
  # handed the correct path to.
  #
  # The view that works is the one in which the mountpoint's own path is still written out,
  # which is the subvolume lifted by the depth of the mountpoint it was going to be mounted at:
  #
  #     subvol=nix         at /nix        ->  the top level, where the store is nix/store/...
  #     subvol=@/nix       at /nix        ->  subvol=@,      where the store is nix/store/...
  #     subvol=@/nix/store at /nix/store  ->  subvol=@
  #     subvol=store       at /nix/store  ->  nothing lifts that far; the assertion below
  #
  # `/` is depth zero, so for a root the kernel really is mounting this is the identity and the
  # machine's own subvolume is what it gets. Which is the only correct answer there, that mount
  # being the final one with nothing to come along and remount it.
  liftedSubvol =
    if kernelRoot == null then
      null
    else
      let
        subvol = subvolOf kernelRoot;
        have = if subvol == null then [ ] else pathComponents subvol;
        keep = lib.length have - lib.length (pathComponents kernelRoot.mountPoint);
      in
      if keep < 0 then null else lib.concatStringsSep "/" (lib.take keep have);

  # what the kernel is handed as `rootflags`.
  #
  # For a root the kernel mounts as the final root, the machine's own options less the ones the
  # kernel takes as flags of its own. That mount happens exactly once and nothing remounts it
  # afterwards, so `subvol=`, `noatime` and `compress=` have to be in effect from the first
  # instruction, and this is the only channel they have.
  #
  # For a pivot they are not this mount's options at all. finix-init mounts the store at its
  # declared mountpoint out of `mounts` a moment later, with exactly these options, and what the
  # kernel mounted is the scaffolding the binary is run out of - discarded by the pivot before
  # anything else happens. Passing them here applies one option list to two different mounts,
  # and `subvol=` is the member of it which does damage rather than nothing. The single thing
  # wanted from the device is a view in which `init=` resolves, which is the lift above.
  rootflags =
    if kernelRoot == null then
      [ ]
    else if !virtualRoot then
      lib.filter (opt: !(lib.elem opt ownFlags)) kernelRoot.options
    else
      lib.optional (liftedSubvol != null && liftedSubvol != "") "subvol=${liftedSubvol}";

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
    if kernelRoot == null || kernelRoot.device == null then
      null
    else if kernelResolvable kernelRoot.device then
      translate kernelRoot.device
    else
      let
        other = preferred (lib.filter (d: d != kernelRoot.device) (aliasesFor kernelRoot.device));
      in
      if other == null then null else translate other;

  device = resolved;

  # what the kernel is told to mount as `/`.
  #
  # Normally that is `/` itself. Where `/` is a tmpfs it cannot be: there is no device to name
  # and nothing to populate it with, so the kernel is given the filesystem holding the *store*
  # instead, and finix-init pivots to the declared tmpfs once it is running. That filesystem is
  # the one thing which must be there before anything else can be, being where the binary and
  # everything it runs live.
  kernelRoot =
    if !virtualRoot then
      root
    else
      let
        # `/` excluded, and leaving it out let an unbootable configuration through: `/` is an
        # ancestor of /nix/store like any other path, so a tmpfs root matched its own search and
        # became the thing named to the kernel. Its device is `none`, which resolves to nothing,
        # so no `root=` was emitted and the assertion below - which asks whether anything holds
        # the store - was satisfied by the root it was trying to replace.
        holders = lib.filter (fs: fs.mountPoint != "/" && lib.hasPrefix fs.mountPoint "/nix/store") (
          lib.attrValues config.fileSystems
        );
      in
      lib.foldl' (
        a: b: if a == null || lib.stringLength b.mountPoint > lib.stringLength a.mountPoint then b else a
      ) null holders;

  params = [
    "root=${device}"
  ]
  ++ lib.optional (kernelRoot.fsType != "auto") "rootfstype=${kernelRoot.fsType}"
  ++ lib.optional (rootflags != [ ]) "rootflags=${lib.concatStringsSep "," rootflags}"

  # read-write from the first instruction, unless the machine asked for otherwise.
  #
  # The usual arrangement is the opposite - the kernel mounts read-only, the init checks the
  # filesystem and remounts - and it does not survive here, because activation runs before
  # anything else this system does. On finit it is a plugin at PLUGIN_INIT, and what it writes
  # is /etc, so on a read-only root there is no /etc for finit to read its fstab out of and the
  # boot ends in sulogin. There is nothing to remount with before the thing which does the
  # remounting exists.
  ++ [ (if lib.elem "ro" kernelRoot.options then "ro" else "rw") ]

  # `rootwait`, always.
  #
  # The kernel gives up on a root that is not there yet, and whether it is there is a race it
  # cannot see the other side of: a controller's probe is asynchronous, and a driver built into
  # the kernel is not a driver that has finished binding. Without this the same machine boots or
  # does not depending on how fast its disk answered, which is the worst shape a boot failure can
  # have.
  #
  # Unconditional because there is no case for the other behaviour. Waiting costs nothing on a
  # machine whose root is already there, and the alternative is `VFS: Cannot open root device`
  # from hardware that was about to be ready.
  ++ [ "rootwait" ];

  # filesystems which have to be built before they can be mounted, which is the work a stage 1
  # exists to do. Named by fsType because that is how the contract names them: `luks` and `lvm`
  # are already fsTypes the mount generator skips for the same reason.
  assembled = lib.filter (
    fs:
    lib.elem fs.fsType [
      "luks"
      "lvm"
      "zfs"
      "mdraid"
    ]
    || lib.elem "_netdev" (fs.options or [ ])
  ) early;

  # and the ones expecting an fsck that nothing on this path can perform
  unchecked = lib.filter (fs: !fs.noCheck) early;

  # `neededForBoot` means "mounted before stage 2 init", which is a thing only an initrd can
  # do. `/` is the exception the kernel handles itself.
  # a name only udev makes, and so a name nothing has made yet on this path
  udevPath = d: d != null && lib.hasPrefix "/dev/disk/by-" d;

  # what mount(8) resolves for itself, by reading the disk rather than looking in /dev
  blkidTag =
    d:
    d != null
    && lib.any (t: lib.hasPrefix t d) [
      "UUID="
      "LABEL="
      "PARTUUID="
      "PARTLABEL="
    ];

  # everything `mount -a` will try, which is every filesystem but the root - that one is the
  # kernel's or a stage's, and is already mounted by the time fstab is read
  fstabMounts = lib.filter (fs: fs.mountPoint != "/") (lib.attrValues config.fileSystems);

  # named by a symlink udev has not made yet
  lateNamed = lib.filter (fs: udevPath fs.device) fstabMounts;

  # and the ones finix-init mounts itself, which is mount(2) rather than mount(8): a syscall
  # takes a path, so neither a udev symlink nor one of mount(8)'s tags is a thing it can use
  rawNamed = lib.filter (fs: udevPath fs.device || blkidTag fs.device) early;

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
  # what the kernel is told to mount, by fsType, for whoever has to build a kernel that can.
  #
  # Internal: this module's own answer to "which filesystem does `root=` name", published
  # because boot/kernel.nix needs it and deriving it twice would be deriving it differently.
  # Null wherever this module emits no `root=` at all.
  options.boot.kernelRootFsType = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    internal = true;
    description = ''
      The `fsType` of the filesystem named to the kernel as `root=`, or null where nothing is.

      Normally `fileSystems."/"`. Where `/` is a tmpfs the kernel cannot mount it, so what it is
      given is the filesystem holding the store and this is that one's type.
    '';
  };

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

  # `boot.kernel.enable` as well as the initrd being off.
  #
  # Everything here is about telling a kernel which filesystem to mount and how to find it, and a
  # configuration with no kernel has nothing to tell: a container has neither an initrd nor a
  # kernel, and would otherwise arrive at "boot.initrd.enable is false, so the kernel mounts the
  # root filesystem itself and has to be told which one" for a root nothing is going to mount.
  #
  # Which is the shape of the mistake worth naming: `!initrd.enable` reads as "the direct boot
  # path" and is not. It is every configuration that is not using an initrd, and two of those are
  # not booting at all.
  config = lib.mkIf (config.boot.kernel.enable && !config.boot.initrd.enable) {
    # `device != null` as well: with nothing resolved there is no `root=` to write, and the
    # assertions below are what should report that rather than a coercion error from this string.
    boot.kernelParams = lib.mkIf (kernelRoot != null && device != null) params;

    boot.kernelRootFsType = lib.mkIf (kernelRoot != null) kernelRoot.fsType;

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
        assertion = virtualRoot || root != null;
        message = ''
          boot.initrd.enable is false, so the kernel mounts the root filesystem itself and
          has to be told which one. Declare fileSystems."/".
        '';
      }

      {
        assertion = virtualRoot || root == null || root.device != null;
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
        assertion = virtualRoot || root == null || root.device == null || device != null;
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
      # no assertion against a tmpfs root here any more.
      #
      # It used to say the kernel cannot mount one - true - and conclude that such a machine needs
      # an initrd, which stopped being true when finix-init learned to pivot. The kernel is given
      # the filesystem holding the store instead, and the binary puts the declared tmpfs in place
      # once it is running. What has to hold is that something *does* hold the store, which is the
      # assertion below.

      # the tmpfs root's one prerequisite
      {
        assertion = !virtualRoot || kernelRoot != null;
        message = ''
          fileSystems."/" is ${root.fsType} and boot.initrd.enable is false, so the kernel has
          nothing it can mount as a root: a tmpfs has no device to name and nothing to populate
          it with.

          What it is given instead is the filesystem holding the store, and finix-init pivots to
          the declared tmpfs once it is running - but no fileSystems entry covers /nix/store, so
          there is nothing to name and nothing for the binary to be run out of.

          Give the store a filesystem of its own, or enable the initrd so a stage builds the root.
        '';
      }

      # and that filesystem has to be mountable in a way which leaves the store where the
      # bootspec says it is
      {
        assertion = !virtualRoot || kernelRoot == null || liftedSubvol != null;
        message =
          let
            subvol = subvolOf kernelRoot;
            byId = lib.filter (lib.hasPrefix "subvolid=") (kernelRoot.options or [ ]);
            depth = lib.length (pathComponents kernelRoot.mountPoint);

            why =
              if subvol != null then
                "subvol=${subvol} would have to be lifted ${toString depth} ${
                  if depth == 1 then "component" else "components"
                } and is ${toString (lib.length (pathComponents subvol))} deep."
              else if byId != [ ] then
                "${kernelRoot.mountPoint} names its subvolume by id (${
                  lib.concatStringsSep ", " byId
                }), and an id says nothing about where in the filesystem that subvolume sits - so there is no parent of it to name in its place. Write subvol=<path> and there will be."
              else
                "${kernelRoot.mountPoint} is ${kernelRoot.fsType}, which can only be mounted from its own root - where the store is at ${
                  lib.removePrefix kernelRoot.mountPoint "/nix/store"
                }/..., not at /nix/store/.... Mounting a filesystem from somewhere other than its root is a btrfs feature, and `subvol=` is it.";
          in
          ''
            fileSystems."/" is ${root.fsType} and boot.initrd.enable is false, so the kernel is
            given ${kernelRoot.mountPoint} to mount as its root and execs the init out of it by
            the path the bootspec wrote: /nix/store/...-finix-system/init.

            That path is absolute and the kernel resolves it against what it mounted, so the
            mount has to begin far enough up the filesystem that ${kernelRoot.mountPoint} is
            still part of the path. ${why}

            Four ways out, in the order they are worth taking:

              - mount the store at /nix rather than at /nix/store, so there is one component to
                lift instead of two.
              - put the store on a subvolume with a parent to mount in its place: subvol=@/nix
                at /nix leaves subvol=@, where the store is nix/store/... as written.
              - give the machine a real root instead of a tmpfs. The kernel's mount is then the
                root itself, `init=` resolves against it as a matter of course, and none of this
                applies.
              - set boot.initrd.enable = true, where stage 1 builds the tmpfs and mounts the
                store beneath it before the init runs, and the kernel is never asked to resolve
                a path inside the store at all.
          '';
      }

      # and it has to be mounted again once the pivot is done
      {
        assertion = !virtualRoot || kernelRoot == null || kernelRoot.neededForBoot;
        message = ''
          fileSystems."${kernelRoot.mountPoint}" holds the store and boot.initrd.enable is false,
          so the kernel mounts it to find the init - and then finix-init pivots to the declared
          tmpfs, which takes that mount with it. Nothing would put the store back.

          What the kernel mounted is scaffolding: it is a view of the device chosen so the
          bootspec's own `init=` resolves, it is detached once the pivot is done, and it is not
          the mount the machine asked for. The mount the machine asked for is this entry, and
          finix-init makes it from the list of filesystems marked neededForBoot - which this one
          is not, so the list would not contain it and the pivot would land on an empty tmpfs with
          no store under it.

          Set fileSystems."${kernelRoot.mountPoint}".neededForBoot = true. On a machine whose
          store is its root this is implicit; on one whose root is a tmpfs it has to be said.
        '';
      }

      # `neededForBoot` is no longer refused here.
      #
      # It used to be, and the reason was sound while it held: mounting a filesystem before the
      # init runs is a thing only an initrd can do. finix-init does it now - it reads the list out
      # of finix-init.json and mounts it before activation - so what is left to refuse is not the
      # marking but the kinds of filesystem the kernel and one static binary cannot between them
      # bring into being.
      {
        assertion = assembled == [ ];
        message = ''
          boot.initrd.enable is false, so the only things that exist before the init are the root
          the kernel mounted and the mounts finix-init makes from it. ${
            lib.concatMapStringsSep ", " (fs: "${fs.mountPoint} (${fs.fsType})") assembled
          } ${
            if lib.length assembled == 1 then "needs" else "need"
          } assembling first, which is what a stage 1 is for: unlocking a volume, assembling an
          array, importing a pool, bringing up a network.

          Set boot.initrd.enable = true. finix-init mounts a filesystem; it does not construct one.
        '';
      }

      # and fsck, which cannot happen at all on this path
      {
        assertion = unchecked == [ ];
        message = ''
          boot.initrd.enable is false, so ${lib.concatMapStringsSep ", " (fs: fs.mountPoint) unchecked} ${
            if lib.length unchecked == 1 then
              "is marked neededForBoot and expects"
            else
              "are marked neededForBoot and expect"
          } to be checked, and there is no moment at which that
          could happen. An initrd is where a root gets checked, being the one point at which the
          filesystem is present and not yet mounted; here the first thing to touch it mounts it.

          Set noCheck = true to say so out loud, or enable the initrd so there is something to do
          the checking.
        '';
      }

      # the devices fstab names, which nothing has made yet
      {
        assertion = lateNamed == [ ];
        message = ''
          boot.initrd.enable is false, so ${
            lib.concatMapStringsSep ", " (fs: "${fs.mountPoint} (${toString fs.device})") lateNamed
          } ${
            if lib.length lateNamed == 1 then "is" else "are"
          } mounted by `mount -a` once the init is running - and nothing has run udev by then.
          /dev/disk/by-* is a symlink udev makes, so the mount fails exactly as a missing device
          does.

          It takes the whole boot with it, which is why this is an error and not a warning.
          `mount -a` is one task for every filesystem, so one entry failing fails all of them;
          the sysinit barrier waits on that task for ever, and a machine which never reaches
          sysinit never starts a logger - so the only record of why is on the console, if anyone
          is watching.

          mount(8) resolves these itself, through libblkid, which reads the disk rather than
          looking in /dev:

            /dev/disk/by-partuuid/X   ->  PARTUUID=X
            /dev/disk/by-partlabel/X  ->  PARTLABEL=X
            /dev/disk/by-uuid/X       ->  UUID=X
            /dev/disk/by-label/X      ->  LABEL=X

          by-id, by-path and by-diskseq have no equivalent - they describe what the hardware says
          about itself, which is udev's knowledge and not the disk's - so those have to name the
          device node instead.
        '';
      }

      # and the devices finix-init mounts, where even mount(8)'s own syntax is too late
      {
        assertion = rawNamed == [ ];
        message = ''
          ${
            lib.concatMapStringsSep ", " (fs: "${fs.mountPoint} (${toString fs.device})") rawNamed
          } ${
            if lib.length rawNamed == 1 then "is" else "are"
          } neededForBoot, so finix-init mounts ${
            if lib.length rawNamed == 1 then "it" else "them"
          } before the init runs - and it calls mount(2), which takes a path and nothing else.

          `UUID=`, `LABEL=`, `PARTUUID=` and `PARTLABEL=` are mount(8)'s syntax, resolved by
          libblkid inside a program which is not running here. /dev/disk/by-* is a symlink udev
          makes, and udev is not running either. A syscall can use neither.

          Name the device node: /dev/nvme0n1p5, /dev/sda2. This is the same thing root= asks for
          and for the same reason - there is nothing between the kernel and the disk yet.
        '';
      }
    ];
  };
}
