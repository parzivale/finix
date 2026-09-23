{ config, lib, ... }:
let
  cfg = config.nixpkgs;

  overlayType = lib.mkOptionType {
    name = "nixpkgs-overlay";
    description = "nixpkgs overlay";
    check = lib.isFunction;
    merge = lib.mergeOneOption;
  };
in
{
  options.nixpkgs = {
    pkgs = lib.mkOption {
      type = lib.types.pkgs // {
        description = "An evaluation of Nixpkgs; the top level attribute set of packages";
      };
      description = ''
        The `nixpkgs` package set to use for this system.
      '';
    };

    overlays = lib.mkOption {
      type = lib.types.listOf overlayType;
      default = [ ];
      example = lib.literalExpression ''
        [
          (final: prev: {
            openssh = prev.openssh.override { hpnSupport = true; };
          })
        ]
      '';
      description = ''
        Overlays to apply to {option}`nixpkgs.pkgs`, modifying the package set
        every module sees as `pkgs`.

        A module needing a package the given nixpkgs does not have - or a
        different build of one it does - says so here, rather than the caller
        having to know what every module on the machine will want before it can
        construct the package set. They are applied after any overlays already
        baked into {option}`nixpkgs.pkgs`.

        Unlike NixOS this cannot construct a package set of its own: finix
        takes one it is handed, so there is no `config`, `hostPlatform` or
        `system` here. Those stay with whoever evaluates nixpkgs.

        See the [Overlays chapter in the Nixpkgs manual](https://nixos.org/manual/nixpkgs/stable/#chap-overlays).
      '';
    };
  };

  config = {
    _module.args = {
      pkgs = cfg.pkgs.appendOverlays cfg.overlays;
    };
  };
}
