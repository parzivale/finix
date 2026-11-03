{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.lemurs;

  format = pkgs.formats.toml { };
  configFile = format.generate "config.toml" cfg.settings;

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
  options.services.lemurs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [lemurs](${pkgs.lemurs.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lemurs;
      defaultText = lib.literalExpression "pkgs.lemurs";
      description = ''
        The package to use for `lemurs`.
      '';
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      description = ''
        `lemurs` configuration. See [upstream documentation](https://github.com/coastalwhite/lemurs/blob/main/extra/config.toml)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.lemurs.settings = {
      tty = 7;
      # TODO: sync with pam environment variables
      initial_path = "${config.security.wrapperDir}:/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin";
      pam_service = "lemurs";

      power_controls = {
        base_entries = [
          {
            # The text in the top-left to display how to shutdown.
            hint = "Shutdown";

            # The color and modifiers of the hint in the top-left corner
            hint_color = "dark gray";
            hint_modifiers = "";

            # The key used to shutdown. Possibilities are F1 to F12.
            key = "F1";
            # The command that is executed when the key is pressed
            cmd = "${config.finit.package}/bin/initctl poweroff";
          }

          {
            # The text in the top-left to display how to reboot.
            hint = "Reboot";

            # The color and modifiers of the hint in the top-left corner
            hint_color = "dark gray";
            hint_modifiers = "";

            # The key used to reboot. Possibilities are F1 to F12.
            key = "F2";
            # The command that is executed when the key is pressed
            cmd = "${config.finit.package}/bin/initctl reboot";
          }
        ];
      };

      wayland.wayland_sessions_path = "/run/current-system/sw/share/wayland-sessions";

      x11 = lib.mkIf config.programs.xorg.enable or false {
        xauth_path = "/run/current-system/sw/bin/xauth";
        xserver_path =
          if config.security.wrappers.X.enable or false then
            "${config.security.wrapperDir}/X"
          else
            (lib.getExe config.programs.xorg.package);
        xsessions_path = "/run/current-system/sw/share/xsessions";
        xsetup_path = "${cfg.package}/etc/xsetup.sh";
      };
    };

    security.pam.services = lib.optionalAttrs (cfg.settings.pam_service == "lemurs") {
      lemurs.rules = {
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
          # https://github.com/coastalwhite/lemurs/issues/166
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
            order = 12200;
            control = "required";
            modulePath = "pam_limits.so";
          };
        };
      };
    };

    environment.etc."lemurs/config.toml".source = configFile;

    # disable the tty that lemurs runs on
    finit.ttys."tty${toString cfg.settings.tty}".enable = false;

    finit.services.lemurs = {
      description = "lemurs terminal user interface display/login manager";
      conditions = "service/syslogd/ready";
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/lemurs tty${toString cfg.settings.tty}";
      cgroup.user = { };
    };
  };
}
