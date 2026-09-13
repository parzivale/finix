# what services.ly puts on a terminal, as a providers.ttys device
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
  cfg = config.services.ly;
in
{
  config = lib.mkIf cfg.enable {
    # ly takes the terminal it runs on, which is the whole of what it has to say: the getty
    # which would otherwise be there is a default definition of this same device, and this
    # overrides it. Disabling that getty separately - `finit.ttys.<dev>.enable = false` - was a
    # thing only finit heard, so on any other init both held the device at once.
    #
    # The seat and session managers are named nowhere now: they are in earlier tiers, and
    # `multi-user` - the default for a terminal - is already behind all of them. `runlevels =
    # "34"` goes with them, having meant that on a machine booting to 2 ly never started.
    providers.ttys.devices."tty${toString cfg.tty}" = {
      description = "ly terminal display/login manager";

      # agetty opens the terminal and hands the session to ly, which is how a greeter gets a
      # device it can take over
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/ly tty${toString cfg.tty}";
    };
  };
}
