# how services.greetd runs, as providers.services units
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
  cfg = config.services.greetd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.greetd = {
      description = "greeter daemon";
      # a switch does not restart this, however much its definition changed.
      #
      # Restarting a greeter ends every session on the machine, so a switch which touched it
      # would log the user out without being asked to - and when the switch is being run from
      # one of those sessions, it takes the rest of the switch with it. That is how a generation
      # comes to be activated and never recorded: the tool driving it is killed between
      # activating and writing the profile, and the next boot is the one before the change.
      #
      # The same conclusion nixos reaches for every display manager it ships, in the same words:
      # "Don't kill a user session when using nixos-rebuild".
      #
      # What this gives up is that the greeter keeps running with the definition it started from
      # until something restarts it - a reboot, or `initctl restart greetd` by someone who meant
      # it. That is the right trade for a unit whose restart is a logout.
      restartIfChanged = false;

      # `multi-user`, like any other login prompt: a greeter before the system is up offers a
      # session into a half-built machine. `runlevels = "34"` had no contract equivalent - the
      # trunk has no notion of a level a service is simply not considered on - and on a machine
      # booting to 2 it meant greetd never started at all.
      #
      # The session and seat managers are in earlier tiers, and so are their socket gates, so
      # none of them is named here - a greeter starts a compositor, and what a compositor needs
      # is the seat socket answering, which the tier before this one has already waited for.
      requires = [ "multi-user" ];

      type.service.command = "${pkgs.greetd}/bin/greetd --config ${cfg.configFile}";
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/cache/tuigreet";
        type.directory = {
          user = "greeter";
          group = "greeter";
        };
      }
    ];
  };
}
