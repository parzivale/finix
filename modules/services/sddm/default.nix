{
  modules,
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sddm;

  format = pkgs.formats.ini { };
  configFile = format.generate "sddm.conf" cfg.settings;

  package' = cfg.package.override (prev: {
    extraPackages = prev.extraPackages or [ ] ++ cfg.extraPackages;
  });

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
  imports = [ modules.xorg ];

  options.services.sddm = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sddm](${pkgs.kdePackages.sddm.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kdePackages.sddm;
      defaultText = lib.literalExpression "pkgs.kdePackages.sddm";
      description = ''
        The package to use for `sddm`.
      '';
    };

    extraPackages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      example = ''
        with pkgs.kdePackages; [
          breeze-icons
          kirigami
          libplasma
          plasma5support
          qtmultimedia
          qtsvg
          qtvirtualkeyboard
        ]
      '';
      description = ''
        Extra Qt plugins / QML libraries to add to the environment.
      '';
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      example = {
        Autologin = {
          User = "john";
          Session = "plasma.desktop";
        };
      };
      description = ''
        Extra settings merged in and overwriting defaults in sddm.conf.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.xorg.enable = true;

    services.sddm.settings = {
      General = {
        HaltCommand =
          if config.services.elogind.enable then
            "/run/current-system/sw/bin/loginctl poweroff"
          else
            "${config.providers.privileges.command} /run/current-system/sw/bin/poweroff";
        RebootCommand =
          if config.services.elogind.enable then
            "/run/current-system/sw/bin/loginctl reboot"
          else
            "${config.providers.privileges.command} /run/current-system/sw/bin/reboot";
        Numlock = "none";

        # Implementation is done via pkgs/applications/display-managers/sddm/sddm-default-session.patch
        DefaultSession = ""; # optionalString (config.services.displayManager.defaultSession != null) "${config.services.displayManager.defaultSession}.desktop";

        DisplayServer = "x11";
      };
      X11 = {
        # MinimumVT = 7;
        ServerPath = "${config.programs.xorg.package.out}/bin/X";
        XephyrPath = "${config.programs.xorg.package.out}/bin/Xephyr";
        SessionCommand = "${package'}/share/sddm/scripts/Xsession";
        SessionDir = "/run/current-system/sw/share/xsessions";
        XauthPath = "${pkgs.xauth}/bin/xauth";
        # DisplayCommand = toString Xsetup;
        # DisplayStopCommand = toString Xstop;
        # EnableHiDPI = cfg.enableHidpi;

        # Path to the user session log file
        SessionLogFile = ".local/share/sddm/xorg-session.log";

        ServerArguments = "-logverbose 6 -xkbdir ${config.programs.xorg.xkb.dir} -terminate -verbose 7";
      };
      Wayland = {
        SessionCommand = "${package'}/share/sddm/scripts/wayland-session";
        SessionDir = "/run/current-system/sw/share/wayland-sessions";

        # Path to the user session log file
        SessionLogFile = ".local/share/sddm/wayland-session.log";

        # EnableHiDPI = cfg.enableHidpi;
      };
    };

    finit.tmpfiles.rules = [
      # Home dir of the sddm user, also contains state.conf
      "d       /var/lib/sddm   0750    sddm    sddm"
      # This contains X11 auth files passed to Xorg and the greeter
      "d       /run/sddm       0711    root    root"
      # Sockets for IPC
      "r      /tmp/sddm-auth*" # TODO: r!
      # xauth files passed to user sessions
      "r      /tmp/xauth_*" # TODO: r!
      # "r!" above means to remove the files if existent (r), but only at boot (!).
      # tmpfiles.d/tmp.conf declares a periodic cleanup of old /tmp/ files, which
      # would ordinarily result in the deletion of our xauth files. To prevent that
      # from happening, explicitly tag these as X (ignore).
      "X       /tmp/sddm-auth*"
      "X       /tmp/xauth_*"
    ];

    services.dbus.packages = [ package' ];

    environment.systemPackages = [
      package'
    ];

    environment.etc."sddm.conf".source = configFile;
    environment.pathsToLink = [
      "/share/sddm"
    ];

    providers.privileges.rules = lib.mkIf config.services.seatd.enable [
      {
        command = "/run/current-system/sw/bin/reboot";
        users = [ "sddm" ];
        requirePassword = false;
      }
      {
        command = "/run/current-system/sw/bin/poweroff";
        users = [ "sddm" ];
        requirePassword = false;
      }
    ];

    finit.services.sddm = {
      description = "sddm display manager";
      runlevel = "34";
      conditions = [
        "service/syslogd/ready"
      ]
      ++ lib.optionals config.services.sessiond.enable [ "service/sessiond/ready" ]
      ++ lib.optionals config.services.elogind.enable [ "service/elogind/ready" ]
      ++ lib.optionals config.services.seatd.enable [ "service/seatd/ready" ];
      command = "/run/current-system/sw/bin/sddm";
    };

    users.users.sddm = {
      home = "/var/lib/sddm";
      group = "sddm";
      uid = config.ids.uids.sddm;
    };

    users.groups = {
      sddm.gid = config.ids.gids.sddm;
    };

    security.pam.services =
      let
        # only allow the sddm user through the greeter service
        sddmOnly = {
          order = 10000;
          control = "required";
          modulePath = "pam_succeed_if.so";
          args = [
            "audit"
            "quiet_success"
            "user"
            "="
            "sddm"
          ];
        };
      in
      {
        sddm.rules = {
          auth.login = {
            order = 10000;
            control = "substack";
            modulePath = "login";
          };
          account.login = {
            order = 10000;
            control = "include";
            modulePath = "login";
          };
          password.login = {
            order = 10000;
            control = "substack";
            modulePath = "login";
          };
          session.login = {
            order = 10000;
            control = "include";
            modulePath = "login";
          };
        };

        sddm-greeter.rules = {
          auth = {
            sddm-only = sddmOnly;
            permit = {
              order = 10100;
              control = "optional";
              modulePath = "pam_permit.so";
            };
          };

          account = {
            sddm-only = sddmOnly;
            unix = {
              order = 10100;
              control = "sufficient";
              modulePath = "pam_unix.so";
            };
          };

          password.deny = {
            order = 10000;
            control = "required";
            modulePath = "pam_deny.so";
          };

          session = {
            sddm-only = sddmOnly;
            env = {
              order = 10100;
              control = "required";
              modulePath = "pam_env.so";
              settings = {
                conffile = "/etc/security/pam_env.conf";
                readenv = 0;
              };
            };
            rundir = lib.mkIf (session_rundir != null) {
              order = 10200;
              control = "optional";
              modulePath = session_rundir;
            };
            keyinit = {
              order = 10300;
              control = "optional";
              modulePath = "pam_keyinit.so";
              settings = {
                force = true;
                revoke = true;
              };
            };
            permit = {
              order = 10400;
              control = "optional";
              modulePath = "pam_permit.so";
            };
            limits = {
              order = 10500;
              control = "required";
              modulePath = "pam_limits.so";
            };
          };
        };

        sddm-autologin.rules = {
          auth = {
            nologin = {
              order = 10000;
              control = "requisite";
              modulePath = "pam_nologin.so";
            };
            root-uid = {
              order = 10100;
              control = "required";
              modulePath = "pam_succeed_if.so";
              args = [
                "uid"
                ">="
                (toString 0)
                "quiet"
              ];
            };
            permit = {
              order = 10200;
              control = "required";
              modulePath = "pam_permit.so";
            };
          };

          account.sddm = {
            order = 10000;
            control = "include";
            modulePath = "sddm";
          };
          password.sddm = {
            order = 10000;
            control = "include";
            modulePath = "sddm";
          };
          session.sddm = {
            order = 10000;
            control = "include";
            modulePath = "sddm";
          };
        };
      };
  };
}
