# the driver symlinks, as providers.services rules
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.hardware.graphics;

  # the driver trees the symlinks point at. Restated here rather than shared with graphics.nix:
  # a `let` cannot cross a module boundary, and these are three lines each.
  driversEnv = pkgs.buildEnv {
    name = "graphics-drivers";
    paths = [ cfg.package ] ++ cfg.extraPackages;
  };

  driversEnv32 = pkgs.buildEnv {
    name = "graphics-drivers-32bit";
    paths = [ cfg.package32 ] ++ cfg.extraPackages32;
  };
in
{
  config = lib.mkIf cfg.enable {
    providers.services.tmpfiles.rules = [
      {
        type = "symlink";
        path = "/run/opengl-driver";
        argument = "${driversEnv}";
      }
    ]
    ++ lib.optional cfg.enable32Bit {
      type = "symlink";
      path = "/run/opengl-driver-32";
      argument = "${driversEnv32}";
    };
  };
}
