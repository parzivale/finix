{
  lib,
  pkgs,
  config,
  ...
}:
let
  format = pkgs.formats.toml { };
  cfg = config.services.sessiond-hooks;
in
{
  imports = [ ./providers.services.nix ];

  options.services.sessiond-hooks = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sessiond-hooks](${pkgs.sessiond-hooks.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sessiond-hooks;
      defaultText = lib.literalExpression "pkgs.sessiond-hooks";
      description = ''
        The package to use for `sessiond-hooks`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            settings = lib.mkOption {
              inherit (format) type;
              description = "Hook settings serialized to TOML.";
            };
          };
        }
      );
      example = {
        dinit.settings = {
          on_start = "${lib.getExe' pkgs.dinit "dinit"} --user --services-dir /etc/dinit.d/user";
          restart = {
            on = "Failure";
            delay = 5;
          };
        };
      };
      default = { };
      description = ''
        Per-user session hooks launched. Each named entry spawns an
        independent `sessiond-hooks` process.
      '';
    };
  };
}
