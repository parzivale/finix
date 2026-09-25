{
  options,
  pkgs,
  lib,
  ...
}:

let
  inherit (lib)
    mkOption
    types
    ;
in
{
  options = {

    virtualisation.cores = mkOption {
      type = types.ints.positive;
      default = 1;
      description = ''
        Specify the number of cores the guest is permitted to use.
        The number can be higher than the available cores on the
        host system.
      '';
    };

    virtualisation.memorySize = mkOption {
      type = types.ints.positive;
      default = 1024;
      description = ''
        The memory size in megabytes of the virtual machine.
      '';
    };

    # The same declaration as `fileSystems`, reused rather than restated - this is the same
    # kind of thing, said about a machine which does not exist yet.
    virtualisation.fileSystems = options.fileSystems // {
      description = ''
        The filesystems a virtual machine mounts, in the shape of {option}`fileSystems`.

        Collected here separately and installed into `fileSystems` in one go, which is the only
        way a real machine's disks can be replaced by a virtual machine's. `lib.mkVMOverride`
        applied to `fileSystems` directly would not do it: a higher-priority definition of an
        option discards the lower-priority ones outright rather than merging with them, so
        overriding the root mount would take the 9p store mount away with it. Everything the
        virtual machine wants goes in here, and this is what gets overridden in.
      '';
    };

    virtualisation.hostFileSystems = mkOption {
      type = types.raw;
      default = { };
      internal = true;
      description = ''
        The mounts the machine itself declares, handed to its virtual-machine variant by
        `build-vm.nix` so that the variant can stand in for them.

        Internal because it is plumbing rather than a setting: the variant is replacing these
        and so cannot read them from `fileSystems`, that being the option it is defining.
      '';
    };
    virtualisation.host.pkgs = mkOption {
      type = types.raw;
      default = pkgs;
      defaultText = lib.literalExpression "pkgs";
      description = ''
        The package set to build the things which run on the *host* from: qemu itself, and the
        script which starts it.

        Distinct from `pkgs`, which builds the guest. The two are the same set for a virtual
        machine of the machine's own architecture, and must not be for any other - a qemu built
        for the guest cannot run on the host at all.
      '';
    };

  };
}
