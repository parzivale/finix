{
  config,
  pkgs,
  lib,
  ...
}:

let
  qemuCommand =
    qemuPkg:
    let
      hostStdenv = qemuPkg.stdenv;
      hostSystem = hostStdenv.system;
      guestSystem = pkgs.stdenv.hostPlatform.system;

      linuxHostGuestMatrix = {
        x86_64-linux = [
          "${qemuPkg}/bin/qemu-system-x86_64"
          "-machine"
          "accel=kvm:tcg"
          "-cpu"
          "max"
        ];
        armv7l-linux = [
          "${qemuPkg}/bin/qemu-system-arm"
          "-machine"
          "virt,accel=kvm:tcg"
          "-cpu"
          "max"
        ];
        aarch64-linux = [
          "${qemuPkg}/bin/qemu-system-aarch64"
          "-machine"
          "virt,gic-version=max,accel=kvm:tcg"
          "-cpu"
          "max"
        ];
        powerpc64le-linux = [
          "${qemuPkg}/bin/qemu-system-ppc64"
          "-machine"
          "powernv"
        ];
        powerpc64-linux = [
          "${qemuPkg}/bin/qemu-system-ppc64"
          "-machine"
          "powernv"
        ];
        riscv32-linux = [
          "${qemuPkg}/bin/qemu-system-riscv32"
          "-machine"
          "virt"
        ];
        riscv64-linux = [
          "${qemuPkg}/bin/qemu-system-riscv64"
          "-machine"
          "virt"
        ];
        x86_64-darwin = [
          "${qemuPkg}/bin/qemu-system-x86_64"
          "-machine"
          "accel=kvm:tcg"
          "-cpu"
          "max"
        ];
      };
      otherHostGuestMatrix = {
        aarch64-darwin = {
          aarch64-linux = [
            "${qemuPkg}/bin/qemu-system-aarch64"
            "-machine"
            "virt,gic-version=2,accel=hvf:tcg"
            "-cpu"
            "max"
          ];
          inherit (otherHostGuestMatrix.x86_64-darwin) x86_64-linux;
        };
        x86_64-darwin = {
          x86_64-linux = [
            "${qemuPkg}/bin/qemu-system-x86_64"
            "-machine"
            "type=q35,accel=hvf:tcg"
            "-cpu"
            "max"
          ];
        };
      };

      throwUnsupportedHostSystem =
        let
          supportedSystems = [ "linux" ] ++ (lib.attrNames otherHostGuestMatrix);
        in
        throw "Unsupported host system ${hostSystem}, supported: ${lib.concatStringsSep ", " supportedSystems}";
      throwUnsupportedGuestSystem =
        guestMap:
        throw "Unsupported guest system ${guestSystem} for host ${hostSystem}, supported: ${lib.concatStringsSep ", " (lib.attrNames guestMap)}";
    in
    if hostStdenv.hostPlatform.isLinux then
      linuxHostGuestMatrix.${guestSystem} or "${qemuPkg}/bin/qemu-kvm"
    else
      let
        guestMap = (otherHostGuestMatrix.${hostSystem} or throwUnsupportedHostSystem);
      in
      (guestMap.${guestSystem} or (throwUnsupportedGuestSystem guestMap));

  cfg = config.virtualisation.qemu;

  useBootLoader = cfg.bootMode != "kernel";

  bootModeArgs = {
    kernel = [
      "-kernel"
      "${config.boot.kernelPackages.kernel}/${
        config.boot.kernelPackages.kernel.target
          or config.boot.kernelPackages.stdenv.hostPlatform.linux-kernel.target
      }"
      "-initrd"
      "${config.boot.initrd.package}/initrd"
      "-append"
      (toString (config.boot.kernelParams ++ [ "init=${config.system.topLevel}/init" ]))
    ];

    # the firmware boots whatever it finds on the disks configured below; the
    # variable store is a writable per-run copy, made by whoever starts the VM.
    uefi = [
      "-drive"
      "if=pflash,format=raw,unit=0,readonly=on,file=${cfg.firmware.firmware}"
      "-drive"
      "if=pflash,format=raw,unit=1,file=${cfg.efiVariablesFile}"
    ];
  };
in
{
  imports = [ ./common.nix ];

  options = {
    virtualisation.qemu = {
      package = lib.mkPackageOption pkgs [ "qemu" ] { };

      bootMode = lib.mkOption {
        type = lib.types.enum [
          "kernel"
          "uefi"
        ];
        default = "kernel";
        description = ''
          Boot method used to load the guest.
        '';
      };

      firmware = lib.mkOption {
        type = lib.types.package;
        default = pkgs.OVMF.fd;
        defaultText = lib.literalExpression "pkgs.OVMF.fd";
        description = ''
          UEFI firmware for {option}`virtualisation.qemu.bootMode` `"uefi"`,
          providing `firmware` and `variables` images.
        '';
      };

      efiVariablesFile = lib.mkOption {
        type = lib.types.str;
        default = "efi-vars.fd";
        description = ''
          Where the guest's EFI variable store lives, relative to the directory
          the VM is started in. Copied from the firmware's template by whoever
          starts the VM, so that NVRAM writes do not reach the Nix store.
        '';
      };

      disks = lib.mkOption {
        default = { };
        example = lib.literalExpression ''
          { esp = { file = "../esp.img"; size = "512M"; }; }
        '';
        description = ''
          Raw disk images to attach. Each is created at `size` by whoever starts
          the VM if it does not exist yet, so a path outside the VM's own run
          directory can be used to hand a disk from one machine to another.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options.file = lib.mkOption {
                type = lib.types.str;
                default = "${name}.img";
                defaultText = lib.literalExpression ''"''${name}.img"'';
                description = "Path to the image, relative to the VM's run directory.";
              };

              options.size = lib.mkOption {
                type = lib.types.str;
                default = "1G";
                description = "Size to create the image at, if it is not there already.";
              };
            }
          )
        );
      };

      argv = lib.mkOption {
        type = with lib.types; listOf str;
        readOnly = true;
        description = ''
          Command-line for starting the host QEMU.
        '';
      };

      extraArgs = lib.mkOption {
        type = with lib.types; listOf str;
        description = ''
          Extra command-line options for starting the host QEMU.
        '';
      };

      sharedDirectories = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options.source = lib.mkOption {
              type = lib.types.str;
              description = "The path of the directory to share, can be a shell variable";
            };
            options.target = lib.mkOption {
              type = lib.types.path;
              description = "The mount point of the directory inside the virtual machine";
            };
            options.securityModel = lib.mkOption {
              type = lib.types.enum [
                "passthrough"
                "mapped-xattr"
                "mapped-file"
                "none"
              ];
              default = "mapped-xattr";
              description = ''
                The security model to use for this share:

                - `passthrough`: files are stored using the same credentials as they are created on the guest (this requires QEMU to run as root)
                - `mapped-xattr`: some of the file attributes like uid, gid, mode bits and link target are stored as file attributes
                - `mapped-file`: the attributes are stored in the hidden .virtfs_metadata directory. Directories exported by this security model cannot interact with other unix tools
                - `none`: same as "passthrough" except the sever won't report failures if it fails to set file attributes like ownership
              '';
            };
          }
        );
        default = { };
        example = {
          my-share = {
            source = "/path/to/be/shared";
            target = "/mnt/shared";
          };
        };
        description = ''
          An attributes set of directories that will be shared with the
          virtual machine using VirtFS (9P filesystem over VirtIO).
          The attribute name will be used as the 9P mount tag.
        '';
      };

      nics = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              args = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ ];
                example = [ "model=virtio-net-pci" ];
              };
            };
          }
        );
        default = { };
        description = ''
          Network interface cards to add to the VM.
        '';
      };

      mountHostNixStore = lib.mkOption {
        type = lib.types.bool;
        default = !useBootLoader;
        defaultText = lib.literalExpression ''config.virtualisation.qemu.bootMode == "kernel"'';
        description = ''
          Mount the host Nix store as a 9p mount.
        '';
      };

    };
  };

  config = {

    boot.initrd.kernelModules = [
      "virtio_pci" # TODO: platforms without PCI.
      "virtio_blk"
      "virtio_console"
      "virtio_net"
    ]
    ++ lib.optional (cfg.sharedDirectories != { }) "9pnet_virtio";

    fileSystems = lib.mkMerge (
      [
        (lib.mapAttrs' (tag: share: {
          name = share.target;
          value.device = tag;
          value.fsType = "9p";
          value.neededForBoot = true;
          value.options = [
            "trans=virtio"
            "version=9p2000.L"
          ]
          ++ lib.optional (tag == "nix-store") "cache=loose";
        }) cfg.sharedDirectories)
      ]
      ++ lib.optional cfg.mountHostNixStore {
        "/nix/store" = {
          device = "/nix/.ro-store";
          fsType = "none";
          options = [ "bind" ];
        };
      }
    );

    virtualisation.qemu.argv =
      (qemuCommand cfg.package)
      ++ bootModeArgs.${cfg.bootMode}
      ++ [
        "-m"
        (toString config.virtualisation.memorySize)
        "-smp"
        (toString config.virtualisation.cores)
      ]
      ++ (lib.flatten (
        lib.mapAttrsToList (tag: share: [
          "-virtfs"
          "local,path=${share.source},mount_tag=${tag},security_model=${share.securityModel},readonly=on"
        ]) cfg.sharedDirectories
      ))
      ++ lib.flatten (
        lib.mapAttrsToList (_: disk: [
          "-drive"
          "file=${disk.file},format=raw,if=virtio"
        ]) cfg.disks
      )
      ++ lib.flatten (
        lib.mapAttrsToList (
          name:
          { args }:
          [
            "-nic"
            (lib.concatStringsSep "," (args ++ [ "id=${name}" ]))
          ]
        ) cfg.nics
      )
      ++ cfg.extraArgs;

    virtualisation.qemu.sharedDirectories = {
      nix-store = lib.mkIf cfg.mountHostNixStore {
        source = builtins.storeDir;
        # Always mount this to /nix/.ro-store because we never want to actually
        # write to the host Nix Store.
        target = "/nix/.ro-store";
        securityModel = "none";
      };
    };

  };
}
