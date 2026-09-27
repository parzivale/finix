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

    # what the initramfs is for, which is not the same question as whether there is one.
    #
    #   stage  it mounts a root and hands the machine over to it. The usual arrangement, and
    #          what `enable` on its own means.
    #   root   it *is* the root. Nothing is handed over: the kernel's rootfs is the root the
    #          machine keeps, /init mounts what the store is on, and `boot.init` is PID 1 from
    #          the first instruction.
    #   none   there is no initramfs. The kernel mounts the root itself from `root=`, so the root
    #          has to be something it can mount and every driver it needs has to be built in.
    #
    # Defaulted from `enable` rather than inferred from the root's shape, and that is a deliberate
    # retreat from something which looked better. `enable = false` with a tmpfs root has exactly
    # one possible meaning - the kernel cannot mount a root with no device and nothing to
    # populate it with - so the role can be read off those two facts and for a while it was.
    #
    # What that costs is a dependency loop. Reading the root's shape means reading
    # `fileSystems`, and the modules which most need to know the role are the ones which *define*
    # fileSystems: `boot/root.nix` sets noCheck on `/`, and qemu's `mountHostNixStore` decides
    # whether the host store is shared, which becomes a mount. Gate either on an inferred role and
    # the module system reports `infinite recursion encountered` naming `fileSystems` and the role
    # and nothing about which definition tied them together.
    #
    # Defaulting from `enable` alone depends on nothing, so those gates are free - and the
    # contradictions the inference would have made unrepresentable are caught by the assertions
    # below instead. Which is the honest trade: an assertion says the same thing as an inference,
    # a moment later and out loud.
    role = lib.mkOption {
      type = lib.types.enum [
        "stage"
        "root"
        "none"
      ];
      default = if config.boot.initrd.enable then "stage" else "none";
      defaultText = lib.literalMD ''`"stage"` if {option}`boot.initrd.enable`, otherwise `"none"`'';
      description = ''
        What the initramfs is for: to mount a root and hand over to it (`stage`), to be the root
        (`root`), or nothing, because there is not one (`none`).

        `root` is the one worth setting by hand. It suits a machine whose root is a tmpfs and
        whose store is on a filesystem that needs no assembling - nothing to unlock, nothing to
        wait for - where a stage that mounts a root and switches into it is a step with nothing
        in it. The image stays; what goes is the handover.
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
      assertions =
        let
          root = config.fileSystems."/" or null;
          virtualRoot =
            root != null
            && lib.elem root.fsType [
              "tmpfs"
              "ramfs"
            ];
        in
        [
          # the pairs the role can be in disagreement with, each of which the old inference could
          # not have expressed. An assertion is where they go now.
          {
            assertion = cfg.role == "root" -> cfg.enable;
            message = ''
              boot.initrd.role is "root", so the initramfs is the root filesystem - but
              boot.initrd.enable is false, so there is no initramfs to be it.

              Leave enable alone: in this role there is still an image, and the bootloader still
              loads it. What is absent is the handover to something else.
            '';
          }

          {
            assertion = cfg.role != "none" -> cfg.enable;
            message = ''
              boot.initrd.role is "${cfg.role}", which describes an initramfs, but
              boot.initrd.enable is false. Set the role to "none" if this machine has no
              initramfs, or leave enable on.
            '';
          }

          {
            assertion = cfg.role == "root" -> virtualRoot;
            message = ''
              boot.initrd.role is "root", so the initramfs is the root - but fileSystems."/" is
              ${if root == null then "not set" else root.fsType}, which is a filesystem to be
              mounted, and mounting one over the root the machine is already running from would
              take the store with it.

              This role wants a root the kernel brought into being and nothing else claims: a
              tmpfs or a ramfs. Name the filesystem the store is on as neededForBoot instead, and
              /init will mount it.
            '';
          }
        ];
    }

    {
      warnings = lib.optionals (cfg.fileSystemImportCommands != "") [
        "boot.initrd.fileSystemImportCommands has been deprecated; please use boot.initrd.finit.tasks instead"
      ];
    }

    # everything below describes an image, so none of it means anything in the `none` mode - see
    # modules/boot/root.nix for what happens instead. It does mean something in `root`, where the
    # image is not a stage on the way to a root but the root itself, so this is the mode rather
    # than `enable`: that is off in `root` mode and an image is still wanted.
    (lib.mkIf (cfg.role != "none") {
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
