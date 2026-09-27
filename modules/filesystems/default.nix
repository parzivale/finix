{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  # https://wiki.archlinux.org/index.php/fstab#Filepath_spaces
  escape = string: lib.replaceStrings [ " " "\t" ] [ "\\040" "\\011" ] string;

  fileSystems' = lib.toposort utils.fsBefore (lib.attrValues config.fileSystems);

  fileSystems =
    if fileSystems' ? result then
      # use topologically sorted fileSystems everywhere
      fileSystems'.result
    else
      # the assertion below will catch this,
      # but we fall back to the original order
      # anyway so that other modules could check
      # their assertions too
      (lib.attrValues config.fileSystems);

  makeSwapEntry =
    sw:
    let
      device = if sw.label != null then "/dev/disk/by-label/${sw.label}" else sw.device;
      options =
        sw.options
        ++ lib.optional (sw.priority != null) "pri=${toString sw.priority}"
        ++ lib.optional (sw.discardPolicy != null) (
          if sw.discardPolicy == "both" then "discard" else "discard=${sw.discardPolicy}"
        );
    in
    "${escape device} none swap ${escape (lib.concatStringsSep "," options)} 0 0\n";

  makeFstabEntries =
    let
      fsToSkipCheck = [
        "none"
        "auto"
        "overlay"
        "iso9660"
        "bindfs"
        "udf"
        "btrfs"
        "zfs"
        "tmpfs"
        "bcachefs"
        "nfs"
        "nfs4"
        "nilfs2"
        "vboxsf"
        "squashfs"
        "glusterfs"
        "apfs"
        "9p"
        "cifs"
        "prl_fs"
        "vmhgfs"
        "ntfs3"
      ]
      ++
        lib.optionals false # (!config.boot.initrd.checkJournalingFS)
          [
            "ext3"
            "ext4"
            "reiserfs"
            "xfs"
            "jfs"
            "f2fs"
          ];
      isBindMount = fs: lib.elem "bind" fs.options;
      skipCheck =
        fs: fs.noCheck || fs.device == "none" || lib.elem fs.fsType fsToSkipCheck || isBindMount fs;
    in
    fstabFileSystems:
    { }:
    lib.concatMapStrings (
      fs:
      (
        if fs.device != null then
          escape fs.device
        else
          throw "No device specified for mount point ‘${fs.mountPoint}’."
      )
      + " "
      + escape fs.mountPoint
      + " "
      + fs.fsType
      + " "
      + escape (lib.concatStringsSep "," fs.options)
      + " 0 "
      + (
        if skipCheck fs then
          "0"
        else if fs.mountPoint == "/" then
          "1"
        else
          "2"
      )
      + "\n"
    ) fstabFileSystems;

  # Swap entries with randomEncryption.enable can't be stable fstab lines: the backing device is a fresh /dev/mapper/<name> created with a brand new random key on every boot, so they're set up imperatively instead
  isEncryptedSwap = sw: sw.randomEncryption.enable;
  plainSwapDevices = lib.filter (sw: !isEncryptedSwap sw) config.swapDevices;
  encryptedSwapDevices = lib.filter isEncryptedSwap config.swapDevices;

in
{
  imports = [
    ./providers.services.nix
    ./options.nix

    ./9p.nix
    ./binfmt_misc.nix
    ./btrfs.nix
    ./efivarfs.nix
    ./ext2.nix
    ./ext4.nix
    ./f2fs.nix
    ./fuse.mergerfs.nix
    ./fuse.nix
    ./iso9660.nix
    ./luks.nix
    ./lvm.nix
    ./ntfs3.nix
    ./overlay.nix
    ./special.nix
    ./squashfs.nix
    ./tmpfs.nix
    ./vfat.nix
    ./xfs.nix
    ./zfs.nix
  ];

  config = {
    # Add the mount helpers to the system path so that `mount' can find them.
    # system.fsPackages = [ pkgs.dosfstools ];
    # environment.systemPackages = with pkgs; [ fuse3 fuse ] ++ config.system.fsPackages;

    assertions = lib.map (sw: {
      assertion = sw.label == null && (builtins.match "/dev/disk/by-(uuid|label)/.*" sw.device == null);
      message = ''
        Random-encrypted swap device ${sw.device} must not use swapDevices.*.label,
        and should not be referenced by UUID or label, since those are erased and regenerated on every
        boot once the partition is encrypted. Use a stable path such as
        /dev/disk/by-partuuid/... instead.
      '';
    }) encryptedSwapDevices;

    environment.systemPackages =
      lib.unique (
        lib.flatten (
          lib.concatMap (v: lib.optional v.enable v.packages or [ ]) (
            lib.attrValues config.boot.supportedFilesystems
          )
        )
      )
      ++ lib.optional (encryptedSwapDevices != [ ]) pkgs.cryptsetup;

    environment.etc.fstab.text = ''
      # This is a generated file.  Do not edit!
      #
      # To make changes, edit the fileSystems and swapDevices NixOS options
      # in your /etc/nixos/configuration.nix file.
      #
      # <file system> <mount point>   <type>  <options>       <dump>  <pass>

      # filesystems
      ${makeFstabEntries (lib.filter (
        fs:
        !lib.elem fs.fsType [
          "luks"
          "lvm"
        ]
        # `/` too, when the initramfs is the root.
        #
        # With `boot.initrd.pivot = false` there is no stage which mounts a root and hands over
        # to it: the kernel's rootfs is the root, and by the time anything reads this file the
        # store has already been mounted into it. An entry for `/` then describes something to
        # be mounted which is already mounted, and what is being asked for is worse than
        # redundant - `none / tmpfs size=6G,mode=755` is a *fresh* tmpfs, so honouring it puts an
        # empty filesystem over the running root and takes /nix, /etc and /bin out of view with
        # it. finit acts on fstab before anything else, so that is the first thing it does.
        #
        # This is the other half of `boot.initrd.pivot`. /init already excludes `/` from what it
        # mounts, for the same reason and by the same test; nothing was telling this file.
        && !(fs.mountPoint == "/" && config.boot.initrd.enable && !config.boot.initrd.pivot)
      ) fileSystems) { }}

      # swap devices (random-encrypted swap is set up by a unit - see providers.services.nix)
      ${lib.concatMapStrings makeSwapEntry plainSwapDevices}
    '';

    boot.supportedFilesystems = lib.mapAttrs' (
      _: v: lib.nameValuePair v.fsType { enable = true; }
    ) config.fileSystems;
  };
}
