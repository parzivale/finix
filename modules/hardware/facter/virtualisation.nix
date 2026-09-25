# What the report says about the machine being a guest, and what follows from it.
#
# Two thirds of nixos' version ports directly: the kvm module for the host cpu, and the
# virtio drivers a qemu guest needs in its initrd. The last third does not - `virtualbox`
# and `hyperv` guest integrations and `hardware.parallels` are nixos module trees with no
# counterpart here, so a guest on one of those gets its kernel modules and nothing else.
# Named here rather than silently absent, since the difference is visible: no guest agent,
# no clipboard or resizing.
{
  lib,
  config,
  ...
}:
let
  inherit (config.hardware.facter) report;
  cfg = config.hardware.facter.detected.virtualisation;
in
{
  options.hardware.facter.detected.virtualisation = {
    virtio_scsi.enable = lib.mkEnableOption "Enable the Facter Virtualisation Virtio SCSI module" // {
      default = lib.any (
        { vendor, device, ... }:
        # vendor (0x1af4) Red Hat, Inc.
        (vendor.value or 0) == 6900
        &&
          # device (0x1004, 0x1048) Virtio SCSI
          (lib.elem (device.value or 0) [
            4100
            4168
          ])
      ) (report.hardware.scsi or [ ]);
      defaultText = "hardware dependent";
    };
    oracle.enable = lib.mkEnableOption "Enable the Facter Virtualisation Oracle module" // {
      default = report.virtualisation or null == "oracle";
      defaultText = "environment dependent";
    };
    parallels.enable = lib.mkEnableOption "Enable the Facter Virtualisation Parallels module" // {
      default = report.virtualisation or null == "parallels";
      defaultText = "environment dependent";
    };
    qemu.enable = lib.mkEnableOption "Enable the Facter Virtualisation Qemu module" // {
      default = builtins.elem (report.virtualisation or null) [
        "qemu"
        "kvm"
        "bochs"
      ];
      defaultText = "environment dependent";
    };
    hyperv.enable = lib.mkEnableOption "Enable the Facter Virtualisation Hyper-V module" // {
      default = report.virtualisation or null == "microsoft";
      defaultText = "environment dependent";
    };
    # no virtualisation detected
    none.enable = lib.mkEnableOption "Enable the Facter Virtualisation None module" // {
      default = report.virtualisation or null == "none";
      defaultText = "environment dependent";
    };
  };

  config = lib.mkIf config.hardware.facter.enable {
    warnings =
      let
        unsupported = lib.filter (guest: guest.enable) [
          {
            inherit (cfg.oracle) enable;
            name = "VirtualBox";
          }
          {
            inherit (cfg.hyperv) enable;
            name = "Hyper-V";
          }
          {
            inherit (cfg.parallels) enable;
            name = "Parallels";
          }
        ];
      in
      lib.optional (unsupported != [ ]) ''
        nixos-facter detected this machine as a ${
          lib.concatMapStringsSep "/" (guest: guest.name) unsupported
        } guest, and there is no guest-additions module here to enable. The kernel modules
        the report names are loaded; the guest agent is not, so shared clipboard, shared
        folders and display resizing will not work.
      '';

    # KVM support
    boot.kernelModules =
      let
        hasCPUFeature =
          feature:
          lib.any (
            {
              features ? [ ],
              ...
            }:
            lib.elem feature features
          ) (report.hardware.cpu or [ ]);
      in
      lib.mkMerge [
        (lib.mkIf (hasCPUFeature "vmx") [ "kvm-intel" ])
        (lib.mkIf (hasCPUFeature "svm") [ "kvm-amd" ])
      ];

    # virtio & qemu
    boot.initrd = {
      kernelModules = lib.optionals cfg.qemu.enable [
        "virtio_balloon"
        "virtio_console"
        "virtio_rng"
        "virtio_gpu"
      ];

      availableKernelModules = lib.mkMerge [
        (lib.mkIf cfg.qemu.enable [
          "virtio_net"
          "virtio_pci"
          "virtio_mmio"
          "virtio_blk"
          "9p"
          "9pnet_virtio"
        ])
        (lib.mkIf cfg.virtio_scsi.enable [
          "virtio_scsi"
        ])
      ];
    };
  };
}
