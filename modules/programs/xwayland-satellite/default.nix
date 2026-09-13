{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.xwayland-satellite;
in
{
  imports = [ ./providers.services.nix ];

  options.programs.xwayland-satellite = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [xwayland-satellite](${pkgs.xwayland-satellite.meta.homepage}).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.xwayland-satellite;
      defaultText = lib.literalExpression "pkgs.xwayland-satellite";
      description = ''
        The package to use for `xwayland-satellite`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # `D!` was create-and-empty-at-boot, which is two rules here: the sockets a previous boot
    # left behind are removed, and the directory is then created with the mode it needs. The
    # `z` rules which followed each `D!` only reasserted that mode, so they are gone with it.
    #
    # These rules run once, from `tmpfiles-setup`, which is what the `!` in `D!` and `r!` asked
    # for - there is no periodic cleaner here to tell "boot only".

  };
}
