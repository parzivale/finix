{
  config,
  pkgs,
  lib,
  ...
}:
let
  inherit (lib.kernel) yes;

  # what each filesystem is called in the kernel's own configuration. A filesystem is more
  # than one symbol often enough - vfat needs the codepages it decodes names with, 9p needs
  # its transport - that naming them by hand is a trap worth taking away.
  #
  # A name missing from here is not a refusal, only an absence: the assertion below points at
  # `boot.kernel.structuredExtraConfig`, which takes the symbols directly and is how anything
  # this table has never heard of gets built in.
  filesystemConfig = {
    "9p" = {
      NET_9P = yes;
      NET_9P_VIRTIO = yes;
      "9P_FS" = yes;
    };
    btrfs.BTRFS_FS = yes;
    # nixpkgs kernels read ext2 and ext3 with the ext4 driver rather than the standalone ones
    ext2 = {
      EXT4_FS = yes;
      EXT4_USE_FOR_EXT2 = yes;
    };
    ext4.EXT4_FS = yes;
    f2fs.F2FS_FS = yes;
    fuse.FUSE_FS = yes;
    iso9660.ISO9660_FS = yes;
    ntfs3.NTFS3_FS = yes;
    overlay.OVERLAY_FS = yes;
    squashfs = {
      SQUASHFS = yes;
      SQUASHFS_XZ = yes;
      SQUASHFS_ZSTD = yes;
    };
    tmpfs.TMPFS = yes;
    vfat = {
      FAT_FS = yes;
      VFAT_FS = yes;
      NLS_CP437 = yes;
      NLS_ISO8859_1 = yes;
    };
    xfs.XFS_FS = yes;
  };

  root = config.fileSystems."/" or null;

  # the root is the one filesystem the kernel has to mount unaided, and only when there is no
  # initrd to mount it instead. Everything else in `fileSystems` is mounted after init starts,
  # by which time a module is an ordinary thing to load - and an initrd carries the module for
  # the root itself, which is what it is for.
  #
  # Derived whether or not the kernel looks like it already has it. There was a filter here
  # which skipped the ones nixpkgs builds in, to save a machine an unnecessary kernel build,
  # and the list behind it was read off an aarch64 configuration: on x86_64 ext4, vfat,
  # squashfs and 9p are every one of them modules. What that filter did there was derive
  # nothing for an ordinary ext4 root and leave the machine with a kernel which had no block
  # filesystem at all - `Can't find any bdev filesystem to be used for mount!`, then a panic.
  #
  # There is nothing to save anyway: a machine without an initrd builds a kernel regardless,
  # because the storage drivers are built into it, so this costs it nothing.
  #
  # `auto` is not a filesystem, so there is nothing to look up; an fsType this has never heard
  # of is left to the warning below rather than silently dropped.
  derived = lib.optional (
    !config.boot.initrd.enable && root != null && filesystemConfig ? ${root.fsType}
  ) root.fsType;

  # the same idea for the controller the root disk hangs off, which is the other half of what
  # a kernel needs in order to reach a root unaided: knowing ext4 is no use if nothing can
  # talk to the disk the ext4 is on.
  #
  # Keyed by the kernel module's own name, so that a list of modules is what this takes - which
  # is what everything else which knows the answer already produces. `lsmod` on a running
  # machine names them this way, and so does nixos-facter: its report gives every storage
  # controller a `driver_modules`, which is what it feeds to boot.initrd.availableKernelModules
  # on a machine that has an initrd. A machine with a report can hand the same list here.
  #
  # Each entry carries whatever that module actually needs, which is more than the module's own
  # symbol: a disk is not reachable through its controller alone, so the block layer it appears
  # through comes with it.
  driverConfig = {
    ahci = {
      ATA = yes;
      SATA_AHCI = yes;
      SATA_AHCI_PLATFORM = yes;
      SCSI = yes;
      BLK_DEV_SD = yes;
    };
    mmc_block = {
      MMC = yes;
      # MMC_BLOCK depends on `RPMB || !RPMB`, which reads as no dependency at all and is not
      # one: a tristate cannot be built in while something it depends on is a module, and
      # RPMB is `m` in the kernel nixpkgs builds. Left out, the config generator refuses the
      # `y`, asks the same question again, and the build fails on the repeat rather than on
      # anything which names the reason.
      RPMB = yes;
      MMC_BLOCK = yes;
      MMC_SDHCI = yes;
      MMC_SDHCI_PCI = yes;
    };
    nvme = {
      # NVME_CORE has no prompt and is `select`ed by this, so it needs no line of its own
      BLK_DEV_NVME = yes;

      # nixpkgs asks for NVME_AUTH as a module, and that is only reachable while the driver
      # itself is one: NVME_HOST_AUTH is a bool, it is `y` there, and a bool selecting a
      # tristate under a built-in parent makes it `y` too. So building NVMe in promotes this
      # whatever anyone wanted, and the kernel's own configuration check fails on the
      # difference. Forced rather than set, because it is overriding a value nixpkgs states
      # outright rather than filling in one it left open.
      NVME_AUTH = lib.mkForce yes;
    };
    sd_mod = {
      SCSI = yes;
      BLK_DEV_SD = yes;
    };
    usb_storage = {
      USB_STORAGE = yes;
      SCSI = yes;
      BLK_DEV_SD = yes;
    };
    virtio_blk = {
      VIRTIO = yes;
      VIRTIO_PCI = yes;
      VIRTIO_BLK = yes;
    };
  };

  knownDrivers = lib.attrNames driverConfig;
  unknownDrivers = lib.filter (d: !(driverConfig ? ${d})) config.boot.kernel.builtinDrivers;

  # every one of them, on a machine with no initrd.
  #
  # Which of these a particular machine needs is a question about hardware, and the
  # configuration does not reliably answer it: a root named by label or by uuid says nothing
  # about what it is on, and those are how most machines name their disks. Guessing from a
  # /dev path covers the machines which spell it out and quietly fails the rest - and failing
  # means a kernel which cannot find its root, which is a panic, on hardware, with no way to
  # ask it anything.
  #
  # Building all of them in costs nothing over building one, because a machine without an
  # initrd is having a kernel built for it either way: whatever it needs is a module in the
  # kernel nixpkgs builds. Which ones exactly varies by architecture - on x86_64 even SATA and
  # virtio are modules, where on aarch64 they are not - and that is the second reason not to
  # try to name only the necessary ones.
  #
  # A machine which knows what it is can still say so, `[ ]` included.
  allDrivers = lib.optionals (!config.boot.initrd.enable) knownDrivers;

  known = lib.attrNames filesystemConfig;
  unknown = lib.filter (fs: !(filesystemConfig ? ${fs})) config.boot.kernel.builtinFilesystems;

  fromFilesystems = lib.foldl lib.recursiveUpdate { } (
    map (fs: filesystemConfig.${fs} or { }) config.boot.kernel.builtinFilesystems
  );

  fromDrivers = lib.foldl lib.recursiveUpdate { } (
    map (d: driverConfig.${d} or { }) config.boot.kernel.builtinDrivers
  );

  structuredConfig = fromFilesystems // fromDrivers // config.boot.kernel.structuredExtraConfig;
in
{
  options = {
    boot.kernel.enable =
      lib.mkEnableOption "the Linux kernel. This is useful for systemd-like containers which do not require a kernel"
      // {
        default = true;
      };

    boot.kernel.features = lib.mkOption {
      default = { };
      example = lib.literalExpression "{ debug = true; }";
      internal = true;
      description = ''
        This option allows to enable or disable certain kernel features.
        It's not API, because it's about kernel feature sets, that
        make sense for specific use cases. Mostly along with programs,
        which would have separate nixos options.
        `grep features pkgs/os-specific/linux/kernel/common-config.nix`
      '';
    };

    boot.kernelPackages = lib.mkOption {
      default = pkgs.linuxPackages;
      type = lib.types.raw;
      apply =
        kernelPackages:
        kernelPackages.extend (
          self: super: {
            kernel = super.kernel.override (originalArgs: {
              inherit (config.boot.kernel) randstructSeed;
              kernelPatches = (originalArgs.kernelPatches or [ ]) ++ config.boot.kernelPatches;
              features = lib.recursiveUpdate super.kernel.features config.boot.kernel.features;
            });
          }
        );
      # We don't want to evaluate all of linuxPackages for the manual
      # - some of it might not even evaluate correctly.
      defaultText = lib.literalExpression "pkgs.linuxPackages";
      example = lib.literalExpression "pkgs.linuxKernel.packages.linux_5_10";
      description = ''
        This option allows you to override the Linux kernel used by
        NixOS.  Since things like external kernel module packages are
        tied to the kernel you're using, it also overrides those.
        This option is a function that takes Nixpkgs as an argument
        (as a convenience), and returns an attribute set containing at
        the very least an attribute {var}`kernel`.
        Additional attributes may be needed depending on your
        configuration.  For instance, if you use the NVIDIA X driver,
        then it also needs to contain an attribute
        {var}`nvidia_x11`.

        Please note that we strictly support kernel versions that are
        maintained by the Linux developers only. More information on the
        availability of kernel versions is documented
        [in the Linux section of the manual](https://nixos.org/manual/nixos/unstable/index.html#sec-kernel-config).
      '';
    };

    boot.kernelPatches = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            name = "foo";
            patch = ./foo.patch;
            extraStructuredConfig.FOO = lib.kernel.yes;
            features.foo = true;
          }
          {
            name = "foo-ml-mbox";
            patch = (fetchurl {
              url = "https://lore.kernel.org/lkml/19700205182810.58382-1-email@domain/t.mbox.gz";
              hash = "sha256-...";
            });
          }
        ]
      '';
      description = ''
        A list of additional patches to apply to the kernel.

        Every item should be an attribute set with the following attributes:

        ```nix
        {
          name = "foo";                 # descriptive name, required

          patch = ./foo.patch;          # path or derivation that contains the patch source
                                        # (required, but can be null if only config changes
                                        # are needed)

          extraStructuredConfig = {     # attrset of extra configuration parameters without the CONFIG_ prefix
            FOO = lib.kernel.yes;       # (optional)
          };                            # values should generally be lib.kernel.yes,
                                        # lib.kernel.no or lib.kernel.module

          features = {                  # attrset of extra "features" the kernel is considered to have
            foo = true;                 # (may be checked by other NixOS modules, optional)
          };

          extraConfig = "FOO y";        # extra configuration options in string form without the CONFIG_ prefix
                                        # (optional, multiple lines allowed to specify multiple options)
                                        # (deprecated, use extraStructuredConfig instead)
        }
        ```

        There's a small set of existing kernel patches in Nixpkgs, available as `pkgs.kernelPatches`,
        that follow this format and can be used directly.
      '';
    };

    boot.kernel.randstructSeed = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "my secret seed";
      description = ''
        Provides a custom seed for the {var}`RANDSTRUCT` security
        option of the Linux kernel. Note that {var}`RANDSTRUCT` is
        only enabled in NixOS hardened kernels. Using a custom seed requires
        building the kernel and dependent packages locally, since this
        customization happens at build time.
      '';
    };

    boot.kernel.builtinFilesystems = lib.mkOption {
      type = with lib.types; listOf str;
      default = derived;
      defaultText = lib.literalMD ''
        the `fsType` of {option}`fileSystems."/"`, on a machine with no initrd - otherwise
        empty
      '';
      example = [ "btrfs" ];
      description = ''
        Filesystems to build into the kernel rather than leave as modules, named the way
        {option}`fileSystems.<name>.fsType` names them.

        Defaulted from the machine's own root filesystem, because on a machine with no initrd
        that is precisely the one the kernel has to be able to mount unaided - so a btrfs root
        needs no second statement that the kernel should understand btrfs.

        Derived whether or not the kernel appears to build it in already, which is not a
        question worth asking: the answer is different per architecture - on x86_64 ext4,
        vfat, squashfs and 9p are all modules, on aarch64 none of them are - and a machine
        without an initrd is building a kernel regardless, since the storage drivers go into
        it.

        Setting this replaces the default rather than adding to it.

        What this is for is a root the kernel has to reach unaided. A module cannot be loaded
        before the filesystem holding it is mounted, so an initrd exists to carry the driver
        for the root across that gap - and a kernel which already has the driver needs no
        initrd at all. See {option}`boot.initrd.enable`.

        Only needed for a filesystem the kernel does not already build in: the stock
        `pkgs.linuxPackages` has ext4, 9p, squashfs and virtio among others, and adding one
        of those here asks for a kernel build which changes nothing.

        Anything this option has not heard of is named directly in
        {option}`boot.kernel.structuredExtraConfig`.
      '';
    };

    boot.kernel.builtinDrivers = lib.mkOption {
      type = with lib.types; listOf str;
      default = allDrivers;
      defaultText = lib.literalMD ''
        all of them, on a machine with no initrd - otherwise empty
      '';
      example = [
        "nvme"
        "ahci"
      ];
      description = ''
        Kernel modules to build into the kernel rather than leave as modules, named the way
        the kernel names them: `nvme`, `ahci`, `sd_mod`, `mmc_block`, `usb_storage`,
        `virtio_blk`.

        The other half of reaching a root without an initrd. Knowing the filesystem is no use
        if nothing in the kernel can talk to the disk it is on, and the kernel nixpkgs builds
        leaves NVMe and MMC as modules - so on most modern hardware, where the root is an NVMe
        disk, {option}`boot.kernel.builtinFilesystems` alone is not enough.

        Named after the modules because that is what everything which knows the answer already
        produces. `lsmod` says `nvme`; so does nixos-facter, whose report gives each storage
        controller a `driver_modules` and which feeds exactly that list to
        {option}`boot.initrd.availableKernelModules` on a machine which has an initrd. A
        machine with a report can hand the same list to this:

        ```nix
        boot.kernel.builtinDrivers = config.facter.detected.boot.disk.kernelModules;
        ```

        A module this has no configuration for is an assertion rather than a silent omission,
        which is the point of naming them rather than deriving them: a machine whose disk hangs
        off something unusual is told so while it can still be fixed, instead of booting to a
        kernel which cannot see it.

        Defaulted to all of them rather than to whichever this machine needs, because a
        configuration does not reliably say which that is: a root named by label or by uuid,
        which is how most machines name their disks, says nothing about what it is on. Building
        all of them in costs nothing over building one, since a machine without an initrd is
        having a kernel built for it either way.

        Set this to `[ ]` to build none of them, on a machine which has some other reason to
        believe its kernel can reach its disk.
      '';
    };

    boot.kernel.structuredExtraConfig = lib.mkOption {
      type = with lib.types; attrsOf raw;
      default = { };
      example = lib.literalExpression "{ BCACHEFS_FS = lib.kernel.yes; }";
      description = ''
        Kernel configuration symbols to set, in the form {manpage}`Kconfig(5)` names them and
        with the values `lib.kernel` builds - `yes`, `module`, `no`, `freeform`, `option`.

        The escape hatch behind {option}`boot.kernel.builtinFilesystems`, and the way to build
        in anything else: whatever is set here is merged over what the filesystem names
        resolved to, so it also overrides them.

        Setting either means building the kernel, which is not a small thing to ask for. A
        machine which can boot with a stock kernel should.
      '';
    };

    boot.resumeDevice = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Device from which to resume after hibernation. Empty = disabled. When set, adds resume=<device> to boot.kernelParams.";
    };

    boot.kernelParams = lib.mkOption {
      type = lib.types.listOf (
        lib.types.strMatching ''([^"[:space:]]|"[^"]*")+''
        // {
          name = "kernelParam";
          description = "string, with spaces inside double quotes";
        }
      );
      default = [ ];
      description = "Parameters added to the kernel command line.";
    };

    boot.extraModulePackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      example = lib.literalExpression "[ config.boot.kernelPackages.nvidia_x11 ]";
      description = "A list of additional packages supplying kernel modules.";
    };

    boot.kernelModules = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      apply = lib.unique;
      description = ''
        The set of kernel modules to be loaded in the second stage of
        the boot process.  Note that modules that are needed to
        mount the root file system should be added to
        {option}`boot.initrd.availableKernelModules` or
        {option}`boot.initrd.kernelModules`.
      '';
    };

    boot.initrd.availableKernelModules = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      apply = lib.unique;
      example = [
        "sata_nv"
        "ext3"
      ];
      description = ''
        The set of kernel modules in the initial ramdisk used during the
        boot process.  This set must include all modules necessary for
        mounting the root device.  That is, it should include modules
        for the physical device (e.g., SCSI drivers) and for the file
        system (e.g., ext3).  The set specified here is automatically
        closed under the module dependency relation, i.e., all
        dependencies of the modules list here are included
        automatically.  The modules listed here are available in the
        initrd, but are only loaded on demand (e.g., the ext3 module is
        loaded automatically when an ext3 filesystem is mounted, and
        modules for PCI devices are loaded when they match the PCI ID
        of a device in your system).  To force a module to be loaded,
        include it in {option}`boot.initrd.kernelModules`.
      '';
    };

    boot.initrd.kernelModules = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      apply = lib.unique;
      description = "List of modules that are always loaded by the initrd.";
    };

    system.modulesTree = lib.mkOption {
      type = with lib.types; listOf path;
      internal = true;
      default = [ ];
      description = ''
        Tree of kernel modules.  This includes the kernel, plus modules
        built outside of the kernel.  Combine these into a single tree of
        symlinks because modprobe only supports one directory.
      '';
      # Convert the list of path to only one path.
      apply =
        let
          kernel-name = config.boot.kernelPackages.kernel.name or "kernel";
        in
        modules: (pkgs.aggregateModules modules).override { name = kernel-name + "-modules"; };
    };
  };

  config = lib.mkIf config.boot.kernel.enable {
    # a patch with no patch in it: `structuredExtraConfig` is how a kernel derivation takes
    # configuration, and boot.kernelPackages already threads boot.kernelPatches into the
    # override. So this needs no second mechanism of its own.
    #
    # `structuredExtraConfig`, not `extraStructuredConfig` - the two names differ by a word
    # order and nixpkgs refuses the older one outright, at build time rather than at
    # evaluation, which is late enough that nothing which only evaluates a configuration will
    # notice. See tests/kernel-config.nix, which builds one.
    boot.kernelPatches = lib.optional (structuredConfig != { }) {
      name = "finix-kernel-config";
      patch = null;
      structuredExtraConfig = structuredConfig;
    };

    warnings =
      lib.optional
        (
          !config.boot.initrd.enable
          && root != null
          && root.fsType != "auto"
          && !(filesystemConfig ? ${root.fsType})
        )
        ''
          fileSystems."/" is ${root.fsType}, which this machine has no initrd to mount for it, and
          which finix has no kernel configuration for - so nothing here can say whether the kernel
          is able to mount it at all.

          If it is not, the machine boots to a kernel panic rather than to anything which could
          report this. Build the filesystem in through boot.kernel.structuredExtraConfig, or give
          the machine an initrd.
        '';

    assertions = [
      {
        assertion = unknown == [ ];
        message = ''
          boot.kernel.builtinFilesystems names ${lib.concatStringsSep ", " unknown}, which
          finix has no kernel configuration for. Known: ${lib.concatStringsSep ", " known}.

          Set the symbols directly in boot.kernel.structuredExtraConfig instead, e.g.
          { BCACHEFS_FS = lib.kernel.yes; }.
        '';
      }

      {
        assertion = unknownDrivers == [ ];
        message = ''
          boot.kernel.builtinDrivers names ${lib.concatStringsSep ", " unknownDrivers}, which
          finix has no kernel configuration for. Known: ${lib.concatStringsSep ", " knownDrivers}.

          Set the symbols directly in boot.kernel.structuredExtraConfig instead, e.g.
          { BLK_DEV_NVME = lib.kernel.yes; }.
        '';
      }
    ];

    # use split output for modules, when available
    system.modulesTree = [
      (config.boot.kernelPackages.kernel.modules or config.boot.kernelPackages.kernel)
    ]
    ++ config.boot.extraModulePackages;

    boot.kernelModules = [
      "loop"
      "atkbd"
    ];

    boot.initrd.availableKernelModules = [
      # Note: most of these (especially the SATA/PATA modules)
      # shouldn't be included by default since nixos-generate-config
      # detects them, but I'm keeping them for now for backwards
      # compatibility.

      # Some SATA/PATA stuff.
      "ahci"
      "sata_nv"
      "sata_via"
      "sata_sis"
      "sata_uli"
      "ata_piix"
      "pata_marvell"

      # NVMe
      "nvme"

      # Standard SCSI stuff.
      "sd_mod"
      "sr_mod"

      # SD cards and internal eMMC drives.
      "mmc_block"

      # Support USB keyboards, in case the boot fails and we only have
      # a USB keyboard, or for LUKS passphrase prompt.
      "uhci_hcd"
      "ehci_hcd"
      "ehci_pci"
      "ohci_hcd"
      "ohci_pci"
      "xhci_hcd"
      "xhci_pci"
      "usbhid"
      "hid_generic"
      "hid_lenovo"
      "hid_apple"
      "hid_roccat"
      "hid_logitech_hidpp"
      "hid_logitech_dj"
      "hid_microsoft"
      "hid_cherry"
      "hid_corsair"

    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isx86 [
      # Misc. x86 keyboard stuff.
      "pcips2"
      "atkbd"
      "i8042"

      # x86 RTC needed by the stage 2 init script.
      "rtc_cmos"
    ];

    boot.kernelParams = lib.mkIf (config.boot.resumeDevice != "") [
      "resume=${config.boot.resumeDevice}"
    ];

    boot.initrd.kernelModules = [
      # For LVM.
      "dm_mod"
    ];
  };
}
