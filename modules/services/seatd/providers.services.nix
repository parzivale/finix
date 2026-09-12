# how services.seatd runs, as providers.services units
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
  cfg = config.services.seatd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.seatd = {
      description = "seat management daemon";

      type.service = {
        command =
          "${pkgs.seatd.bin}/bin/seatd -u root -g ${cfg.group}" + lib.optionalString cfg.debug " -l debug";

        # best first. `-n <fd>` is seatd writing a newline to a descriptor the supervisor
        # chose, which is the s6 protocol - finit and s6-rc observe it directly, and the flag
        # is all they need to be told. dinit and runit cannot, and fall to the socket, which
        # is the thing a compositor actually waits for anyway.
        #
        # Neither needs a unit. This replaces a `seatd-socket` gate whose body was a loop
        # waiting for that same path - written out because the contract had no way to say it
        # at the time, and it has had one since.
        readiness = [
          { s6.flag = "-n"; }
          { waitFor.socket.path = "/run/seatd.sock"; }
        ];
      };

      # no runlevels: the trunk has no notion of a level a service is simply not considered
      # on, which is what `runlevels = "34"` meant here - and on a machine booting to 2 it
      # meant seatd never started, reported as "halted" rather than as anything being wrong.
      #
      # `sysinit` puts it in the basic tier, so a seat exists before `basic` is reached and so
      # before anything attached to it. syslogd is no longer named: it is in the head tier, and
      # everything later is after it by the trunk rather than by each module saying so.
      requires = [ "sysinit" ];
    };
  };
}
