{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.greetd;
  format = pkgs.formats.toml { };

  configFile = format.generate "greetd.toml" cfg.settings;

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
  options.services.greetd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [greetd](${pkgs.greetd.meta.homepage}) as a system service.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `greetd` configuration. See {manpage}`greetd(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    services.greetd.settings = {
      terminal.vt = lib.mkDefault "next";
      default_session = {
        command = lib.mkDefault "${pkgs.greetd}/bin/agreety";
        user = "greeter";
      };
    };

    providers.services.units.greetd = {
      description = "greeter daemon";

      # `multi-user`, like any other login prompt: a greeter before the system is up offers a
      # session into a half-built machine. `runlevels = "34"` had no contract equivalent - the
      # trunk has no notion of a level a service is simply not considered on - and on a machine
      # booting to 2 it meant greetd never started at all.
      #
      # The session and seat managers are in earlier tiers, and so are their socket gates, so
      # none of them is named here - a greeter starts a compositor, and what a compositor needs
      # is the seat socket answering, which the tier before this one has already waited for.
      requires = [ "multi-user" ];

      type.service.command = "${pkgs.greetd}/bin/greetd --config ${configFile}";
    };

    users.users = {
      greeter = {
        isSystemUser = true;
        group = "greeter";
        extraGroups = [
          "video"
        ]
        ++ lib.optionals config.services.elogind.enable [
          "render"
        ]
        ++ lib.optionals config.services.seatd.enable [
          config.services.seatd.group
        ];
      };
    };

    users.groups = {
      greeter = { };
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/cache/tuigreet";
        user = "greeter";
        group = "greeter";
      }
    ];

    security.pam = {
      enable = true;
      services.greetd.text = ''
        # Account management.
        account required pam_unix.so # unix (order 10900)

        # Authentication management.
        auth sufficient pam_unix.so likeauth nullok try_first_pass # unix (order 12800)
        auth required pam_deny.so # deny (order 13600)

        # Password management.
        password sufficient pam_unix.so nullok yescrypt # unix (order 10200)

        # Session management.
        session required pam_env.so conffile=/etc/security/pam_env.conf readenv=0 # env (order 10100)
        session required pam_unix.so # unix (order 10200)
        session required pam_loginuid.so # loginuid (order 10300)
        session required pam_limits.so

        ${lib.optionalString (session_rundir != false) session_rundir}
      '';
    };

  };
}
