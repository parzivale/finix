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
in
{
  config = lib.mkIf cfg.enable {
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
