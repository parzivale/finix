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

    # autologin is hardcoded to run on tty1, so it claims it. That claim is the whole of what
    # used to be `finit.ttys.tty1.enable = lib.mkForce false` plus a service of its own - and
    # the force only ever reached finit, so on any other init a getty held tty1 at the same
    # time and the two fought over the keyboard.
    providers.ttys.devices.tty1 = {
      description = "autologin";

      # the redirect is autologin's own business: unlike a getty it does not take a device, so
      # the terminal has to be its standard streams before it is exec'd. Which is what finit
      # was arranging on its behalf when this was a `tty` stanza with no command.
      command = pkgs.writeShellScript "autologin-tty1" ''
        exec </dev/tty1 >/dev/tty1 2>&1
        exec ${lib.getExe pkgs.autologin} ${cfg.user} ${cfg.command}
      '';

      # `multi-user`, like any other login prompt: a session before the system is up is a
      # session into a half-built machine.
      #
      # That one edge is the whole of it now. This used to name five things one at a time -
      # syslogd, the device manager's settle, elogind, sessiond, seatd's socket - and every one
      # of them is in an earlier tier, including the socket gates, so the trunk says it all.
      requires = [ "multi-user" ];
    };
  };
}
