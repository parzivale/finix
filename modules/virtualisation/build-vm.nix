# `system.build.vm`: this machine, bootable in qemu.
#
# The machine is evaluated a second time, with `vm-variant.nix` on top, and this forwards that
# evaluation's `system.build.vm` out to where a person can build it. A second evaluation rather
# than a switch, because what the variant does is replace the machine's disks and take its
# bootloader away - settings which cannot be present in the configuration being tested without
# changing it into a different one.
#
# Cheap to have around: nothing here is evaluated unless `system.build.vm` is actually asked
# for, which is why this can be loaded by default while `qemu.nix` is not.
{
  config,
  extendModules,
  lib,
  ...
}:
let
  vmVariant = extendModules {
    modules = [ ./vm-variant.nix ];
  };
in
{
  options.virtualisation.vmVariant = lib.mkOption {
    inherit (vmVariant) type;
    default = { };
    visible = "shallow";
    description = ''
      Configuration to add to the machine when it is built as a virtual machine, and to no
      other build of it.

      The place to put whatever a machine needs in order to be worth running in qemu but has no
      business carrying on real hardware - more memory, a mount the test wants to exist, a
      service turned off because the hardware it drives is not there:

      ```nix
      virtualisation.vmVariant = {
        virtualisation.memorySize = 8192;
        virtualisation.fileSystems."/persistent" = {
          device = "tmpfs";
          fsType = "tmpfs";
          neededForBoot = true;
        };
      };
      ```
    '';
  };

  config = {
    system.build.vm = lib.mkDefault config.virtualisation.vmVariant.system.build.vm;

    # A virtual machine of a virtual machine is not a thing this builds, and the recursion it
    # would take to find that out is not a useful error. Refused where it is written instead.
    virtualisation.vmVariant.options.virtualisation.vmVariant = lib.mkOption {
      apply = _: throw "virtualisation.vmVariant.virtualisation.vmVariant is not supported";
    };
  };

  # uses extendModules
  meta.buildDocsInSandbox = false;
}
