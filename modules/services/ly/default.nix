{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.ly;

  format = pkgs.formats.keyValue { };

  brightnessctl = config.programs.brightnessctl.package;

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
  options.services.ly = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [ly](${pkgs.ly.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.ly;
      defaultText = lib.literalExpression "pkgs.ly";
      description = ''
        The package to use for `ly`.
      '';
    };

    tty = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "The TTY that `ly` runs on. Changing this while logged in will exit your session.";
    };

    settings = lib.mkOption {
      inherit (format) type;
      defaultText = lib.literalExpression "See description.";
      description = ''
        `ly` configuration. See [upstream example](https://github.com/fairyglade/ly/blob/master/res/config.ini)
        for additional details.
      '';
      example = lib.literalExpression ''
        {
          animation_frame_delay = 5 # Set delay between animation frames.
          asterisk = "*"; # Set the character used to mask the password.
          bg = "0x20000000"; # Set the background color to black in 0xSSRRGGBB format.
          bigclock_12hr = false; # Set bigclock to 12 hour format.
          battery_id = "null" # Don't show battery (e.g. on a desktop)
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.ly.settings = {
      service_name = "ly";
      waylandsessions = "/run/current-system/sw/share/wayland-sessions";
      setup_cmd = lib.mkDefault "${cfg.package}/etc/setup.sh";

      # defer to pam for PATH
      path = null;

      restart_cmd = "${config.finit.package}/bin/initctl reboot";
      shutdown_cmd = "${config.finit.package}/bin/initctl poweroff";
    }
    // lib.optionalAttrs (lib.versionAtLeast cfg.package.version "1.5.0") {
      # write to syslog
      ly_log = lib.mkDefault null;
    }
    // lib.optionalAttrs config.programs.xorg.enable or false {
      xauth_cmd = "/run/current-system/sw/bin/xauth";
      x_cmd =
        if config.security.wrappers.X.enable or false then
          "${config.security.wrapperDir}/X"
        else
          (lib.getExe config.programs.xorg.package);
      xsessions = "/run/current-system/sw/share/xsessions";
    }
    // lib.optionalAttrs config.programs.brightnessctl.enable or false {
      brightness_up_cmd = lib.mkDefault "${lib.getExe brightnessctl} -q s +10%";
      brightness_down_cmd = lib.mkDefault "${lib.getExe brightnessctl} -q s 10%-";
    };

    environment.etc."ly/config.ini".source = format.generate "config.ini" cfg.settings;
    environment.pathsToLink = [ "/share/ly" ];
    environment.systemPackages = [ cfg.package ];

    security.pam.services = lib.optionalAttrs (cfg.settings.service_name == "ly") {
      ly.rules = {
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
              debug = true;
              conffile = "/etc/security/pam_env.conf";
              readenv = 1;
            };
          };
          unix = {
            order = 10200;
            control = "required";
            modulePath = "pam_unix.so";
          };
          loginuid = {
            order = 10300;
            control = "optional";
            modulePath = "pam_loginuid.so";
          };
          rundir = lib.mkIf (session_rundir != null) {
            order = 10400;
            control = "optional";
            modulePath = session_rundir;
          };
          lastlog = {
            order = 10700;
            control = "required";
            modulePath = "${pkgs.util-linux.lastlog}/lib/security/pam_lastlog2.so";
            settings.silent = true;
          };
          limits = {
            order = 10800;
            control = "required";
            modulePath = "pam_limits.so";
          };
        };
      };
    };

    # Disable the tty that ly runs on
    finit.ttys."tty${toString cfg.tty}".enable = false;

    finit.services.ly = {
      description = "ly terminal display/login manager";
      runlevel = "34";
      conditions = [
        "service/syslogd/ready"
      ]
      ++ lib.optionals config.services.elogind.enable [ "service/elogind/ready" ]
      ++ lib.optionals config.services.seatd.enable [ "service/seatd/ready" ];
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/ly tty${toString cfg.tty}";
      reload-signal = "none";
      cgroup.user = { };
    };
  };
}
