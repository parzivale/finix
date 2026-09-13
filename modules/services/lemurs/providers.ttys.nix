# what services.lemurs puts on a terminal, as a providers.ttys device
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
  cfg = config.services.lemurs;
in
{
  config = lib.mkIf cfg.enable {
    # lemurs takes the terminal it runs on, which is the whole of what it has to say: the
    # getty which would otherwise be there is a default definition of this same device, and
    # this overrides it. Disabling that getty separately - `finit.ttys.<dev>.enable = false` -
    # was a thing only finit heard, so on any other init both held the device at once.
    providers.ttys.devices."tty${toString cfg.settings.tty}" = {
      description = "lemurs terminal user interface display/login manager";

      # agetty opens the terminal and hands the session to lemurs, which is how a greeter gets
      # a device it can take over
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/lemurs tty${toString cfg.settings.tty}";
    };
  };
}
