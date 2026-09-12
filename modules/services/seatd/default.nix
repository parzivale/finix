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
        # `-n %n` is gone: that was seatd notifying finit over a descriptor finit picked, and
        # only finit and s6 can observe that kind of readiness. Ready-on-fork plus the wait
        # below says the same thing in a way every backend can express.
        command =
          "${pkgs.seatd.bin}/bin/seatd -u root -g ${cfg.group}" + lib.optionalString cfg.debug " -l debug";
        readiness = "fork";
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

    # seatd has forked before its socket exists, and a compositor which connects in that
    # window fails to take a seat. Anything needing seatd requires this instead.
    providers.services.units.seatd-socket = {
      description = "wait for the seat management socket";

      # in the same tier as seatd, so anything later has a socket which answers without naming
      # this - and it must be the same tier, since a gate earlier than what it waits for is a
      # cycle through the level between them.
      requires = [
        "sysinit"
        "seatd"
      ];

      type.oneshot.command = pkgs.writeShellScript "seatd-wait" ''
        for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 100); do
          if [ -S /run/seatd.sock ]; then
            exit 0
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        echo "seatd-socket: /run/seatd.sock never appeared" >&2
        exit 1
      '';
    };
  };
}
