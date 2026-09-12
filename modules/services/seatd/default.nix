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
  options.services.seatd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [seatd](${pkgs.seatd.meta.homepage}) as a system service.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "seat";
      description = ''
        Group to own the `seatd` socket.

        ::: {.note}
        If you want non-`root` users to be able to access the `seatd` session, add
        them to this group.
        :::
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups = lib.optionalAttrs (cfg.group == "seat") {
      seat = { };
    };

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
