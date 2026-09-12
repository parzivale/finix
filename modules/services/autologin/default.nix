{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.autologin;

  session_rundir =
    if config.services.sessiond.enable then
      "session optional ${config.services.sessiond.package}/lib/security/pam_sessiond.so"
    else if config.services.elogind.enable then
      "session optional ${pkgs.elogind}/lib/security/pam_elogind.so"
    else if config.services.seatd.enable then
      "session optional ${pkgs.pam_rundir}/lib/security/pam_rundir.so"
    else
      false;
in
{
  options.services.autologin = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [autologin](${pkgs.autologin.meta.homepage}) as a system service.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        User account under which `autologin` runs.

        ::: {.note}
        You are responsible for ensuring the user exists before the `autologin` service starts.
        :::
      '';
    };

    command = lib.mkOption {
      type = lib.types.path;
      description = ''
        Command to execute once {option}`user` is logged in on `tty1`.
      '';
      example = lib.literalExpression ''
        pkgs.writeShellScript "autologin.sh" '''
          exec ''${pkgs.dbus}/bin/dbus-run-session -- ''${lib.getExe pkgs.labwc}
        '''
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # a session started here takes a seat, and one which cannot is not a working session. Two
    # modules can provide one - seatd, and elogind, which is logind and so manages seats itself
    # - so this is a requirement on the pair rather than on either. Ordering after whichever
    # happened to be enabled, and running seatless when neither was, made it invisible.
    assertions = [
      {
        assertion = config.services.seatd.enable || config.services.elogind.enable;
        message = ''
          services.autologin starts a session, which needs a seat manager. Enable
          services.seatd or services.elogind.
        '';
      }
    ];

    security.pam.services.autologin = {
      text = ''
        # Account management.
        account required pam_unix.so # unix (order 10900)

        # Authentication management.
        auth optional pam_unix.so likeauth nullok # unix-early (order 11500)
        auth sufficient pam_unix.so likeauth nullok try_first_pass # unix (order 12800)
        auth required pam_deny.so # deny (order 13600)

        # Password management.
        password sufficient pam_unix.so nullok yescrypt # unix (order 10200)

        # Session management.
        session required pam_env.so conffile=/etc/security/pam_env.conf readenv=0 # env (order 10100)
        session required pam_unix.so # unix (order 10200)
        session required pam_loginuid.so # loginuid (order 10300)
        session required ${config.security.pam.package}/lib/security/pam_lastlog.so silent # lastlog (order 10700)

        ${lib.optionalString (session_rundir != false) session_rundir}
        session required pam_limits.so
      '';
    };

    # autologin is hardcoded to run on tty1
    finit.ttys.tty1.enable = lib.mkForce false;

    providers.services.units.autologin = {
      description = "autologin";

      # finit's `tty` gave this a controlling terminal; the contract has no notion of one,
      # because three of the four implementations have no notion of one either. So the unit
      # takes tty1 for itself - which is what finit was arranging on its behalf.
      type.service = {
        command = pkgs.writeShellScript "autologin-tty1" ''
          exec </dev/tty1 >/dev/tty1 2>&1
          exec ${lib.getExe pkgs.autologin} ${cfg.user} ${cfg.command}
        '';
        readiness = "fork";
      };

      # the session managers wait on their socket rather than on having forked, so that a
      # compositor started from here finds a seat to take
      # `multi-user`, like any other login prompt: a session before the system is up is a
      # session into a half-built machine.
      #
      # The tier supplies almost all of what this used to name one at a time. syslogd and the
      # device manager's settle are in the head tier; elogind and sessiond attach to `basic`.
      # Everything here is in the multi-user tier, so it is after all of them.
      #
      # seatd's socket is named because it is not in a tier, and the socket answering - rather
      # than the daemon having forked - is what a compositor needs. elogind needs nothing here:
      # it attaches to `basic`, so this tier is already after it.
      requires = [
        "multi-user"
      ]
      ++ lib.optional config.services.seatd.enable "seatd-socket";
    };
  };
}
