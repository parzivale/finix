# what services.getty puts on a terminal, as a providers.ttys device
#
# Separated from the module's own options and configuration so that what this module asks of
# the contract is in one place, the same way a module implementing a `providers.*` contract
# keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.getty;

  # The same helper the implementations use for a device claimed with no command. Reached for
  # here because an autologin is not a different program - it is the same agetty with one more
  # argument - and what the helper knows is the part which is easy to get wrong: agetty's
  # compiled-in login program is /bin/login, which does not exist here, so a command built
  # without `--login-program` respawns forever against a missing file.
  loginLib = import ../../providers/ttys/login.nix { inherit pkgs lib; };
in
{
  config = lib.mkIf cfg.enable {
    providers.ttys = {
      inherit (cfg) package extraArgs;

      devices = lib.mkMerge [
        # at default priority, so that a display manager or an autologin claims a device simply
        # by defining it. This module has no idea which terminals something else wants and does
        # not need one: it offers a prompt on each, and whatever else claims one wins.
        #
        # The command is left to the provider. finit runs a login prompt of its own on a device
        # named with no command, which is better than anything this module could pass it, and
        # every other implementation falls back to agetty.
        (lib.genAttrs cfg.ttys (
          device:
          lib.mkDefault {
            description = "getty on /dev/${device}";

            # late: a login prompt before the system is up is a prompt into a half-built
            # machine.
            #
            # Nothing about the seat manager here: elogind attaches to `basic`, so `multi-user`
            # already waits for it. A tier is the place to say "after everything of that kind",
            # and saying it again as an edge would only be a second way to be wrong.
            requires = [ "multi-user" ];
          }
        ))

        # The autologin, where one is asked for: the first of the ttys, claimed at normal
        # priority so that it wins over this module's own prompt for that device. Which is the
        # mechanism the comment above describes, used rather than worked around - and a display
        # manager wanting the same terminal still wins the ordinary way, by saying so.
        #
        # A command has to be named rather than left to the provider, because the provider has
        # no per-device arguments to put `--autologin` in - `providers.ttys.extraArgs` is one
        # list for every terminal, and this argument is for one of them.
        (lib.mkIf (cfg.autologinUser != null) {
          ${lib.head cfg.ttys} =
            let
              device = lib.head cfg.ttys;
            in
            {
              description = "autologin as ${cfg.autologinUser} on /dev/${device}";

              command = loginLib.commandFor {
                inherit device;
                inherit (cfg) package;

                # `--login-pause` waits for a keypress before handing the terminal over. With
                # no prompt to read, that is the only thing which makes whatever the boot left
                # on the screen readable.
                extraArgs = cfg.extraArgs ++ [
                  "--autologin"
                  cfg.autologinUser
                  "--login-pause"
                ];
              };

              requires = [ "multi-user" ];
            };
        })
      ];
    };
  };
}
