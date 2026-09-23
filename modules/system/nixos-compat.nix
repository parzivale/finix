# provides compatibility options so a finix system can be built with `nixos-rebuild`
{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.system.build = lib.mkOption {
    internal = true;
    default = { };

    type = lib.types.submodule {
      freeformType = lib.types.lazyAttrsOf lib.types.anything;

      options = {
        nixos-rebuild = lib.mkOption {
          type = lib.types.package;
          default = pkgs.nixos-rebuild-ng;
          internal = true;
        };

        toplevel = lib.mkOption {
          type = lib.types.anything;
          default = config.system.topLevel;
          internal = true;
        };
      };
    };
  };

  # Said in the vocabulary nixos tooling expects, so that tooling can ask and
  # get an answer rather than an undefined variable. deploy-rs' `activate.nixos`
  # is the case in hand: it reads `boot.loader.systemd-boot.enable` through a
  # `with`, to decide whether to strip the `default` line out of loader.conf,
  # and a missing attribute there is an eval error rather than a falsy value -
  # so the activation script fails to build at all, for a machine that was
  # never going to boot that way.
  options.boot.loader.systemd-boot.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    internal = true;
    description = ''
      Always false: finix does not boot through systemd-boot. Declared so that
      tools written against nixos can read it and find out.
    '';
  };

  config = {
    environment.systemPackages = [
      # nixos-enter and nixos-install depend on a systemd-tmpfiles implementation
      # see https://github.com/NixOS/nixpkgs/blob/80bdc1e5ce51f56b19791b52b2901187931f5353/pkgs/by-name/ni/nixos-enter/nixos-enter.sh#L108 for details
      (lib.lowPrio (
        pkgs.writeShellScriptBin "systemd-tmpfiles" ''
          exec "${config.finit.package}/libexec/finit/tmpfiles" "$@"
        ''
      ))
    ];
  };
}
