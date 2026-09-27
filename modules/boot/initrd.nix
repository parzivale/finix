{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.boot.initrd;

  modulesClosure = pkgs.makeModulesClosure {
    rootModules = config.boot.initrd.availableKernelModules ++ config.boot.initrd.kernelModules;
    kernel = config.system.modulesTree;
    firmware = config.hardware.firmware;
    allowMissing = false;
  };

  fsPackages = lib.unique (
    lib.flatten (
      lib.concatMap (v: lib.optional v.enable v.packages or [ ]) (
        lib.attrValues config.boot.initrd.supportedFilesystems
      )
    )
  );

  initrdPath = pkgs.buildEnv {
    name = "initrd-path";
    paths = cfg.path;
    pathsToLink = [ "/bin" ];
    ignoreCollisions = true;
    postBuild = ''
      # Remove wrapped binaries, they shouldn't be accessible via PATH.
      find $out/bin -maxdepth 1 -name ".*-wrapped" -type l -delete
    '';
  };
in
{
  options.boot.initrd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to enable the NixOS initial RAM disk (initrd). This may be
        needed to perform some initialisation tasks (like mounting
        network/encrypted file systems) before continuing the boot process.
      '';
    };

    pivot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the initramfs hands the machine over to a root filesystem, or is that root
        itself.

        With it on, which is how every machine here has booted so far, the initramfs is a first
        stage: it arranges whatever the real root needs - a device to appear, a volume to open,
        a tmpfs to create and populate - and then `switch_root`s into it, execing
        {option}`boot.init` there. Two inits, two configurations, and `/` is whatever stage one
        mounted.

        With it off there is no handover. The kernel's own rootfs - already a tmpfs, which is
        where an initramfs is unpacked - is the root the machine keeps, and `/init` is a small
        program that mounts the filesystems marked {option}`fileSystems.<name>.neededForBoot`
        and then execs {option}`boot.init` in place. One init, one configuration, and `/` from
        the first instruction.

        What it is for is a machine whose root is a tmpfs anyway. Such a root cannot be reached
        without an initramfs - it has no device to name and nothing to populate it - so the
        handover creates a second tmpfs and moves into it, having already been in one. Turning
        this off skips that.

        What it cannot do is anything stage one does beyond mounting: no LUKS to open, no
        volume group to import, no device to wait for. A machine needing any of those wants the
        stage, which is why this is an option rather than a replacement.

        Not the same as {option}`boot.initrd.enable` being off - that means no initramfs at all
        and a root the kernel mounts from `root=`, which a tmpfs cannot be.
      '';
    };

    compressor = lib.mkOption {
      default =
        if lib.versionAtLeast config.boot.kernelPackages.kernel.version "5.9" then "zstd" else "gzip";
      defaultText = lib.literalExpression "`zstd` if the kernel supports it (5.9+), `gzip` if not";
      type = with lib.types; either str (functionTo str);
      description = ''
        The compressor to use on the initrd image. May be any of:

        - The name of one of the predefined compressors, see {file}`pkgs/build-support/kernel/initrd-compressor-meta.nix` for the definitions.
        - A function which, given the nixpkgs package set, returns the path to a compressor tool, e.g. `pkgs: "''${pkgs.pigz}/bin/pigz"`
        - (not recommended, because it does not work when cross-compiling) the full path to a compressor tool, e.g. `"''${pkgs.pigz}/bin/pigz"`

        The given program should read data from stdin and write it to stdout compressed.
      '';
      example = "xz";
    };

    compressorArgs = lib.mkOption {
      default = null;
      type = with lib.types; nullOr (listOf str);
      description = "Arguments to pass to the compressor for the initrd image, or null to use the compressor's defaults.";
    };

    prepend = lib.mkOption {
      default = [ ];
      type = lib.types.listOf lib.types.str;
      description = ''
        Other initrd files to prepend to the final initrd we are building.
      '';
    };

    contents = lib.mkOption {
      type =
        with lib.types;
        listOf (submodule {
          options = {
            source = lib.mkOption {
              type = types.path;
            };
            target = lib.mkOption {
              type = with types; nullOr str;
              default = null;
            };
          };
        });
      description = ''
        Contents of the initrd.
      '';
    };

    path = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = ''
        Packages whose `/bin` is linked into the initramfs `PATH`.
      '';
    };

    fileSystemImportCommands = lib.mkOption {
      description = ''
        Lines of shell commands that are run after coldbooting
        the device-manager and before mounting file-systems.
      '';
      type = lib.types.lines;
      default = "";
      example = ''
        vgimport --all
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      description = "the initrd to use for your system... use a module to build one";
    };
  };

  config = lib.mkMerge [
    {
      warnings = lib.optionals (cfg.fileSystemImportCommands != "") [
        "boot.initrd.fileSystemImportCommands has been deprecated; please use boot.initrd.finit.tasks instead"
      ];
    }

    # everything below describes an image, so none of it means anything on a machine which
    # boots without one - see modules/boot/root.nix for what happens instead.
    (lib.mkIf cfg.enable {
      boot.initrd.supportedFilesystems = lib.mapAttrs' (
        _: v: lib.nameValuePair v.fsType { enable = true; }
      ) (lib.filterAttrs (_: fs: fs.neededForBoot) config.fileSystems);

      boot.initrd.package = pkgs.makeInitrdNG {
        name = "initrd-" + config.boot.kernelPackages.kernel.name or "kernel";
        inherit (cfg) compressor compressorArgs prepend;
        contents = map (
          { source, target }@pair: if target != null then pair else { inherit source; }
        ) cfg.contents;
      };

      boot.initrd.path = [
        pkgs.busybox

        # needed for at least luks on gardendevd, if not more...
        pkgs.util-linux

        # defer to kmod for modprobe binary
        (lib.hiPrio pkgs.kmod)

        # busybox's own `mount` applet doesn't understand `X-mount.mkdir` and other util-linux specific options used below
        (lib.hiPrio pkgs.util-linux.mount)
      ]
      ++ fsPackages;

      boot.initrd.contents = [
        {
          target = "/lib";
          source = "${modulesClosure}/lib";
        }
        {
          target = "/bin";
          source = "${initrdPath}/bin";
        }
        {
          target = "/sbin";
          source = "${initrdPath}/bin";
        }
      ];
    })
  ];
}
