{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.getty;
in
{
  options.services.getty = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable `getty`.
      '';
    };

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = ''
        The package to use for `getty`.
      '';
      example = lib.literalExpression ''
        pkgs.util-linux // {
          mainProgram = "agetty";
        };
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to {option}`services.getty.package`.
      '';
    };

    ttys = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "tty1"
        "tty2"
        "tty3"
        "tty4"
        "tty5"
        "tty6"
      ];
      description = ''
        The list of tty devices on which to start a login prompt.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc.issue = lib.mkDefault {
      text = ''

        [1;32m<<< welcome to finix >>>[0m

      '';
    };

    providers.ttys = {
      inherit (cfg) package extraArgs;

      # at default priority, so that a display manager or an autologin claims a device simply
      # by defining it. This module has no idea which terminals something else wants and does
      # not need one: it offers a prompt on each, and whatever else claims one wins.
      #
      # The command is left to the provider. finit runs a login prompt of its own on a device
      # named with no command, which is better than anything this module could pass it, and
      # every other implementation falls back to agetty.
      devices = lib.genAttrs cfg.ttys (
        device:
        lib.mkDefault {
          description = "getty on /dev/${device}";

          # late: a login prompt before the system is up is a prompt into a half-built machine.
          #
          # Nothing about the seat manager here: elogind attaches to `basic`, so `multi-user`
          # already waits for it. A tier is the place to say "after everything of that kind",
          # and saying it again as an edge would only be a second way to be wrong.
          requires = [ "multi-user" ];
        }
      );
    };
  };
}
