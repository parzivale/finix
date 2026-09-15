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

  known = lib.attrNames filesystemConfig;
  unknown = lib.filter (fs: !(filesystemConfig ? ${fs})) config.boot.kernel.builtinFilesystems;

  fromFilesystems = lib.foldl lib.recursiveUpdate { } (
    map (fs: filesystemConfig.${fs} or { }) config.boot.kernel.builtinFilesystems
  );

  structuredConfig = fromFilesystems // config.boot.kernel.structuredExtraConfig;
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
      default = [ ];
      example = [ "btrfs" ];
      description = ''
        Filesystems to build into the kernel rather than leave as modules, named the way
        {option}`fileSystems.<name>.fsType` names them.

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
    # a patch with no patch in it: `extraStructuredConfig` is how a kernel derivation takes
    # configuration, and boot.kernelPackages already threads boot.kernelPatches into the
    # override. So this needs no second mechanism of its own.
    boot.kernelPatches = lib.optional (structuredConfig != { }) {
      name = "finix-kernel-config";
      patch = null;
      extraStructuredConfig = structuredConfig;
    };

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
