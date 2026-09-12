{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.getty;

  # finit supplies its own when none is named; nothing else does, so for every other backend
  # the login prompt has to be a real program
  gettyPackage =
    if cfg.package != null then
      cfg.package
    else
      pkgs.util-linux
      // {
        meta = pkgs.util-linux.meta // {
          mainProgram = "agetty";
        };
      };

  # agetty's compiled-in default is /bin/login, and finix has no /bin at all - so without this
  # the prompt never appears and the unit just respawns forever against a missing file
  loginProgram = "/run/current-system/sw/bin/login";

  gettyCommand =
    device:
    lib.concatStringsSep " " (
      [
        (lib.getExe gettyPackage)
        "--login-program"
        loginProgram
        "--noclear"
      ]
      ++ cfg.extraArgs
      ++ [
        device
        "linux"
      ]
    );
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

    # finit has a first-class notion of a tty - it opens the device, handles the session and
    # respawns the prompt when it exits - so under finit these stay finit's own stanzas rather
    # than becoming contract units which would duplicate all of that badly.
    finit.ttys = lib.mkIf (config.providers.services.backend == "finit") (
      lib.genAttrs cfg.ttys (
        device:
        {
          description = "getty on ${device}";
          nowait = true;
        }
        // lib.optionalAttrs (cfg.package != null) {
          command = "${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs} ${device}";
        }
      )
    );

    # every other backend has no tty concept at all, so a login prompt is an ordinary
    # supervised service: agetty opens the device itself, and the supervisor restarts it when
    # a session ends, which is the respawn finit does natively.
    providers.services.units = lib.mkIf (config.providers.services.backend != "finit") (
      lib.genAttrs' cfg.ttys (
        device:
        lib.nameValuePair "getty-${device}" {
          description = "login prompt on ${device}";
          type.service.command = gettyCommand device;

          # late: a login prompt before the system is up is a prompt into a half-built machine
          requires = [ "multi-user" ];
        }
      )
    );
  };
}
