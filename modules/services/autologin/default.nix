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
      "${config.services.sessiond.package}/lib/security/pam_sessiond.so"
    else if config.services.elogind.enable then
      "${pkgs.elogind}/lib/security/pam_elogind.so"
    else if config.services.seatd.enable then
      "${pkgs.pam_rundir}/lib/security/pam_rundir.so"
    else
      null;
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
    security.pam.services.autologin.rules = {
      account.unix = {
        order = 10900;
        control = "required";
        modulePath = "pam_unix.so";
      };

      auth = {
        unix-early = {
          order = 11500;
          control = "optional";
          modulePath = "pam_unix.so";
          settings = {
            likeauth = true;
            nullok = true;
          };
        };
        unix = {
          order = 12800;
          control = "sufficient";
          modulePath = "pam_unix.so";
          settings = {
            likeauth = true;
            nullok = true;
            try_first_pass = true;
          };
        };
        deny = {
          order = 13600;
          control = "required";
          modulePath = "pam_deny.so";
        };
      };

      password.unix = {
        order = 10200;
        control = "sufficient";
        modulePath = "pam_unix.so";
        settings = {
          nullok = true;
          yescrypt = true;
        };
      };

      session = {
        env = {
          order = 10100;
          control = "required";
          modulePath = "pam_env.so";
          settings = {
            conffile = "/etc/security/pam_env.conf";
            readenv = 0;
          };
        };
        unix = {
          order = 10200;
          control = "required";
          modulePath = "pam_unix.so";
        };
        loginuid = {
          order = 10300;
          control = "required";
          modulePath = "pam_loginuid.so";
        };
        lastlog = {
          order = 10700;
          control = "required";
          modulePath = "${pkgs.util-linux.lastlog}/lib/security/pam_lastlog2.so";
          settings.silent = true;
        };
        rundir = lib.mkIf (session_rundir != null) {
          order = 12000;
          control = "optional";
          modulePath = session_rundir;
        };
        limits = {
          order = 12200;
          control = "required";
          modulePath = "pam_limits.so";
        };
      };
    };

    # autologin is hardcoded to run on tty1
    finit.ttys.tty1.enable = lib.mkForce false;

    finit.services.autologin = {
      command = "${lib.getExe pkgs.autologin} ${cfg.user} ${cfg.command}";
      conditions = [
        "service/syslogd/ready"
      ]
      ++ lib.optionals config.services.sessiond.enable [ "service/sessiond/ready" ]
      ++ lib.optionals config.services.elogind.enable [ "service/elogind/ready" ]
      ++ lib.optionals config.services.seatd.enable [ "service/seatd/ready" ];
      log = { };
      reload-signal = "none";
      cgroup.user = { };
      tty = lib.mkForce "/dev/tty1";
    };
  };
}
