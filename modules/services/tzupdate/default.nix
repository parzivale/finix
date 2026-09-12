{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.tzupdate;
in
{
  imports = [ ./providers.services.nix ];

  options.services.tzupdate = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [tzupdate](${pkgs.tzupdate.meta.homepage}) as a system task.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tzupdate;
      defaultText = lib.literalExpression "pkgs.tzupdate";
      description = ''
        The package to use for `tzupdate`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    time.timeZone = null;

  };
}
