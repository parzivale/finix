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
      "session optional ${config.services.sessiond.package}/lib/security/pam_sessiond.so"
    else if config.services.elogind.enable then
      "session optional ${pkgs.elogind}/lib/security/pam_elogind.so"
    else if config.services.seatd.enable then
      "session optional ${pkgs.pam_rundir}/lib/security/pam_rundir.so"
    else
      false;
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
      type = format.type;
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

      restart_cmd = "/run/current-system/sw/bin/reboot";
      shutdown_cmd = "/run/current-system/sw/bin/poweroff";
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
      ly = {
        text = ''
          # Account management.
          account required pam_unix.so
          # Authentication management.
          auth optional pam_unix.so likeauth nullok
          auth sufficient pam_unix.so likeauth nullok try_first_pass
          auth required pam_deny.so
          # Password management.
          password sufficient pam_unix.so nullok yescrypt
          # Session management.
          session required pam_env.so debug conffile=/etc/security/pam_env.conf readenv=1
          session required pam_unix.so
          session optional pam_loginuid.so
          ${lib.optionalString (session_rundir != false) session_rundir}
          session required ${config.security.pam.package}/lib/security/pam_lastlog.so silent
          session required pam_limits.so
        '';
      };
    };

    # ly takes the terminal it runs on, which is the whole of what it has to say: the getty
    # which would otherwise be there is a default definition of this same device, and this
    # overrides it. Disabling that getty separately - `finit.ttys.<dev>.enable = false` - was a
    # thing only finit heard, so on any other init both held the device at once.
    #
    # The seat and session managers are named nowhere now: they are in earlier tiers, and
    # `multi-user` - the default for a terminal - is already behind all of them. `runlevels =
    # "34"` goes with them, having meant that on a machine booting to 2 ly never started.
    providers.ttys.devices."tty${toString cfg.tty}" = {
      description = "ly terminal display/login manager";

      # agetty opens the terminal and hands the session to ly, which is how a greeter gets a
      # device it can take over
      command = "${pkgs.util-linux}/bin/agetty -nil ${cfg.package}/bin/ly tty${toString cfg.tty}";
    };
  };
}
