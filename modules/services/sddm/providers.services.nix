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

    providers.services.tmpfiles.rules = [
      # Home dir of the sddm user, also contains state.conf
      {
        type = "directory";
        path = "/var/lib/sddm";
        mode = "0750";
        user = "sddm";
        group = "sddm";
      }

      # This contains X11 auth files passed to Xorg and the greeter
      {
        type = "directory";
        path = "/run/sddm";
        mode = "0711";
      }

      # the auth files a previous boot left in /tmp. These ran at every boot under finit's
      # reader too - the `r!` which would have made it boot-only is the TODO that was here -
      # and the rules are only run once, by `tmpfiles-setup`, so a glob matching nothing is
      # the ordinary case rather than a mistake.
      #
      # The `X` rules which paired with these are gone: they told a periodic /tmp cleaner to
      # leave these files alone, and the contract's rules describe what to put in place at
      # boot rather than a policy for something else to read later.
      {
        type = "remove";
        path = "/tmp/sddm-auth*";
      }
      {
        type = "remove";
        path = "/tmp/xauth_*";
      }
    ];
  };
}
