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
      "session optional ${config.services.sessiond.package}/lib/security/pam_sessiond.so"
    else if config.services.elogind.enable then
      "session optional ${pkgs.elogind}/lib/security/pam_elogind.so"
    else if config.services.seatd.enable then
      "session optional ${pkgs.pam_rundir}/lib/security/pam_rundir.so"
    else
      false;
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
      type = format.type;
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
            cmd = "/run/current-system/sw/bin/poweroff";
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
            cmd = "/run/current-system/sw/bin/reboot";
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
      lemurs = {
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
          session required pam_env.so debug conffile=/etc/security/pam_env.conf readenv=1 # env (order 10100)
          session required pam_unix.so # unix (order 10200)
          # https://github.com/coastalwhite/lemurs/issues/166
          session optional pam_loginuid.so # loginuid (order 10300)
          ${lib.optionalString (session_rundir != false) session_rundir}
          session required ${config.security.pam.package}/lib/security/pam_lastlog.so silent # lastlog (order 10700)
          session required pam_limits.so
        '';
      };
    };

    environment.etc."lemurs/config.toml".source = configFile;

    # lemurs takes the terminal it runs on, which is the whole of what it has to say: the
    # getty which would otherwise be there is a default definition of this same device, and
    # this overrides it. Disabling that getty separately - `finit.ttys.<dev>.enable = false` -
    # was a thing only finit heard, so on any other init both held the device at once.
    providers.ttys.devices."tty${toString cfg.settings.tty}" = {
      description = "lemurs terminal user interface display/login manager";

      # agetty opens the terminal and hands the session to lemurs, which is how a greeter gets
      # a device it can take over
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/lemurs tty${toString cfg.settings.tty}";
    };
  };
}
