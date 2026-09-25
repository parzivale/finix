# `nvd diff` and `nix-diff` between this system and the same system with the report ignored,
# so that what a hardware report is actually contributing can be read rather than guessed at.
#
# One difference from nixos: there, `system.build.noFacter` is declared as an option. Here
# `system.build` is a single option whose type is a submodule with a freeform
# `lazyAttrsOf anything` (see `modules/system/nixos-compat.nix`), so a second declaration at
# `system.build.noFacter` would collide with it. Assigning is enough - the freeform takes it.
{
  lib,
  pkgs,
  config,
  extendModules,
  ...
}:
{
  options.hardware.facter.debug = {
    nvd = lib.mkOption {
      type = lib.types.package;
      description = ''
        A shell application which will produce an nvd diff of the system closure with and
        without facter enabled.
      '';
    };
    nix-diff = lib.mkOption {
      type = lib.types.package;
      description = ''
        A shell application which will produce a nix-diff of the system closure with and
        without facter enabled.
      '';
    };
  };

  # facter is 'disabled' by forcing the report empty, with one exception: hostPlatform, which
  # a second evaluation cannot do without.
  config.system.build.noFacter = extendModules {
    modules = [
      {
        config.hardware.facter.report = lib.mkForce {
          system = config.nixpkgs.hostPlatform.system;
        };
      }
    ];
  };

  config.hardware.facter.debug = {
    nvd = pkgs.writeShellApplication {
      name = "facter-nvd-diff";
      runtimeInputs = [
        config.services.nix-daemon.package
        pkgs.nvd
      ];
      text = ''
        nvd diff \
          ${config.system.build.noFacter.config.system.topLevel} \
          ${config.system.topLevel} \
          "$@"
      '';
    };

    nix-diff = pkgs.writeShellApplication {
      name = "facter-nix-diff";
      runtimeInputs = [
        config.services.nix-daemon.package
        pkgs.nix-diff
      ];
      text = ''
        nix-diff \
          ${config.system.build.noFacter.config.system.topLevel} \
          ${config.system.topLevel} \
          "$@"
      '';
    };
  };
}
