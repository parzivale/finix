{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.getty;
  # ESC byte via JSON's \u escape
  esc = builtins.fromJSON ''"\u001b"'';
in
{
  imports = [ ./providers.ttys.nix ];

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

    autologinUser = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "bella";
      description = ''
        A user to log in as on the first of {option}`ttys`, with no password asked for.

        The terminal is claimed the way anything else claims one: by defining it, at normal
        priority, over the `mkDefault` prompt this module offers on every tty in the list. A
        display manager which wants that same terminal still wins in the ordinary way, by
        saying so - this is not a special case in the provider.

        Anyone who can open the lid gets that user's session. That is what it is for, and it
        is the whole of the security model around it: set it only where physical access to the
        machine is already the boundary.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc.issue = lib.mkDefault {
      text = ''

        ${esc}[1;32m<<< welcome to finix >>>${esc}[0m

      '';
    };

  };
}
