# a terminal, as a thing an init either has or has to be told how to fake
#
# finit has a first-class notion of one: it opens the device, handles the session and respawns
# the prompt when that session ends, and it says so in its own configuration. dinit, runit and
# s6 have no notion of one at all - there a login prompt is an ordinary supervised process which
# happens to be pointed at a device.
#
# Modules used to write that difference out themselves: `finit.ttys.tty1` in one branch and a
# contract unit in the other, in every module which wanted a terminal. Worse, a module which
# wanted to *take* a terminal from the login prompts - a display manager, an autologin - could
# only say so to finit, as `finit.ttys.tty2.enable = false`, so on every other init it started
# a greeter on a device a getty was already holding and the two fought over the keyboard.
#
# Here a device is claimed by defining it. The login prompts are ordinary definitions at default
# priority, so a display manager's claim simply overrides one; two display managers claiming the
# same device is a merge conflict which names both. Nothing has to be subtracted from anything,
# and nothing has to know which init is running.
#
# This is a provider and not a kind of `providers.services` unit, deliberately. A tty is not a
# daemon - it has no readiness to report and nothing ever depends on one - and giving the
# service contract a notion of one would export a finit peculiarity into the abstraction every
# other implementation has to honour. As a provider it is what it is: one concept, with a native
# implementation where there is one and an emulated implementation where there is not.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.ttys;

  loginLib = import ./login.nix { inherit pkgs lib; };

  pathOrStr = with lib.types; coercedTo path (x: "${x}") str;
  program =
    lib.types.coercedTo (
      lib.types.package
      // {
        check = v: v.type or null == "derivation" && v ? meta.mainProgram;
      }
    ) lib.getExe pathOrStr
    // {
      description = "main program, path or command";
      descriptionClass = "conjunction";
    };

  enabled = lib.filterAttrs (_: device: device.enable) cfg.devices;
in
{
  options.providers.ttys = {
    native = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether the selected init has terminals of its own, and so will be given these
        directly rather than through {option}`providers.services.units`.

        Set by the implementation, not by configuration. When `false`, each device becomes an
        ordinary supervised service running a program which opens the terminal for itself.
      '';
    };

    package = lib.mkOption {
      type = with lib.types; nullOr package;
      default = null;
      description = ''
        The program to run on a device claimed with no {option}`command` of its own.

        `null` leaves it to the implementation: finit has a login prompt built in and uses it,
        and anything else falls back to `agetty`.
      '';
      example = lib.literalExpression ''
        pkgs.util-linux // {
          meta.mainProgram = "agetty";
        }
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments for the login prompt named by {option}`package`.
      '';
    };

    devices = lib.mkOption {
      default = { };
      description = ''
        The terminals this machine runs something on, keyed by device.

        Defining a device claims it: whatever is defined here is the only thing which will be
        started on that terminal. A login prompt is declared at default priority, so a display
        manager or an autologin claims a device simply by defining its {option}`command`.
      '';
      example = lib.literalExpression ''
        {
          tty1.command = "''${pkgs.util-linux}/bin/agetty -nil ''${lib.getExe pkgs.ly} tty1";
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether anything runs on this terminal. A device defined and then disabled
                  is still claimed - nothing else takes it - and simply has no prompt.
                '';
              };

              description = lib.mkOption {
                type = lib.types.str;
                default = "login prompt on ${name}";
                defaultText = lib.literalExpression ''"login prompt on ''${device}"'';
                description = "A short human-readable description of this terminal.";
              };

              command = lib.mkOption {
                type = with lib.types; nullOr program;
                default = null;
                description = ''
                  What to run on this terminal.

                  The program opens the device itself - it is given as the command's own
                  argument - because claiming the terminal, the session and the process group
                  is work only the program can do properly, and every login prompt worth
                  running already does it.

                  `null` asks for a login prompt: {option}`providers.ttys.package`, or the
                  implementation's own where it has one.
                '';
              };

              requires = lib.mkOption {
                type = with lib.types; listOf str;
                default = [ "multi-user" ];
                description = ''
                  The units which must be ready before this terminal is started, in the
                  vocabulary of {option}`providers.services.units`.

                  `multi-user` by default: a prompt offered before the system is up is a
                  session into a half-built machine.
                '';
              };
            };
          }
        )
      );
    };
  };

  # every init without terminals of its own, which is every init but finit. A prompt is a
  # supervised process like any other, and the respawn finit does natively is what a service
  # being restarted when it exits already means.
  config = lib.mkIf (!cfg.native) {
    providers.services.units = lib.mapAttrs' (
      name: device:
      lib.nameValuePair "tty-${name}" {
        inherit (device) description requires;

        type.service.command =
          if device.command != null then
            device.command
          else
            loginLib.commandFor {
              inherit (cfg) package extraArgs;
              device = name;
            };
      }
    ) enabled;
  };
}
