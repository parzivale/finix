# how services.sddm runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sddm;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sddm = {
      description = "sddm display manager";

      # `multi-user`, like any other greeter. The logger, the seat manager and the session
      # manager are all in earlier tiers, so naming them one at a time is no longer the way to
      # be behind them - and `runlevels = "34"` goes with them, having meant that on a machine
      # booting to 2 the greeter never started at all.
      #
      # sddm takes a vt of its own rather than one of the login prompts' - it asks logind or
      # seatd for the next free one - so unlike ly or lemurs it claims no `providers.ttys`
      # device.
      requires = [ "multi-user" ];

      type.service.command = "/run/current-system/sw/bin/sddm";
    };
  };
}
