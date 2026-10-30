{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.polkit;
in
{
  imports = [ ./providers.services.nix ];

  options.services.polkit = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [polkit](${pkgs.polkit.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.polkit;
      defaultText = lib.literalExpression "pkgs.polkit";
      description = ''
        The package to use for `polkit`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.

        ::: {.note}
        This is required in order to see log messages from rule definitions.
        :::
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        /* Log authorization checks. */
        polkit.addRule(function(action, subject) {
          // Make sure to set { services.polkit.debug = true; } in configuration.nix
          polkit.log("user " +  subject.user + " is attempting action " + action.id + " from PID " + subject.pid);
        });

        /* Allow any local user to do anything (dangerous!). */
        polkit.addRule(function(action, subject) {
          if (subject.local) return "yes";
        });
      '';
      description = ''
        Any polkit rules to be added to config (in JavaScript ;-). See:
        <https://www.freedesktop.org/software/polkit/docs/latest/polkit.8.html#polkit-rules>
      '';
    };

    agent.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run a polkit authentication agent in every user's session tree - each user
        with {option}`providers.services.users` declared.

        Without one a polkit question has nobody to ask, and an action that would prompt fails
        instead. The agent shows a dialog, so it has to be inside a graphical session and on its
        bus, which is why it is a user unit and not a system one: it starts with whichever
        session runs the session launcher, and so assumes that session is graphical.
      '';
    };

    agent.command = lib.mkOption {
      type = lib.types.str;
      # built against the polkit the daemon uses, not against `pkgs.polkit`. `package` above is
      # the elogind build when elogind is on, but that reaches the daemon and nothing else; an
      # agent links libpolkit itself, and plain `pkgs.polkit` has `useSystemd` on. Built that
      # way it asks systemd's `sd_pid_get_session`, which looks for a cgroup path like
      # /user.slice/user-1000.slice/session-1.scope - and elogind's are flat, so every process
      # gets "Unable to determine the session we are in: No session for pid" and no prompt ever
      # appears.
      #
      # polkit-gnome because it goes through libpolkit-agent-1, which nixpkgs patches to call
      # the setuid helper at /run/wrappers/bin/polkit-agent-helper-1 that this module installs.
      # Agents which reimplement the protocol - soteria - hardcode /usr/lib/polkit-1 instead,
      # which does not exist here, and exit before contacting polkit at all.
      #
      # `libexec`: the agent is not on the package's PATH and the package declares no main
      # program.
      default = "${
        pkgs.polkit_gnome.override { polkit = cfg.package; }
      }/libexec/polkit-gnome-authentication-agent-1";
      defaultText = lib.literalExpression ''"''${pkgs.polkit_gnome.override { polkit = config.services.polkit.package; }}/libexec/polkit-gnome-authentication-agent-1"'';
      description = ''
        The authentication agent to run, as a command.
      '';
    };

    adminIdentities = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "unix-group:wheel" ];
      example = [
        "unix-user:alice"
        "unix-group:admin"
      ];
      description = ''
        Specifies which users are considered “administrators”, for those
        actions that require the user to authenticate as an
        administrator (i.e. have an `auth_admin`
        value).  By default, this is all users in the `wheel` group.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.optionals config.services.sessiond.enable [
      {
        assertion = pkgs.polkit.override.__functionArgs ? useConsoleKit;
        message = "services.polkit.package is trying to use a feature which doesn't yet exist in your version of polkit - sessiond support; please try updating your nixpkgs source";
      }
    ];

    services.polkit.package = lib.mkMerge [
      (lib.mkIf config.services.sessiond.enable (
        pkgs.polkit.override {
          useConsoleKit = true;
          useSystemd = false;
        }
      ))

      # NOTE: package override required for `loginctl poweroff` to work with elogind
      (lib.mkIf config.services.elogind.enable (pkgs.polkit.override { useSystemd = false; }))
    ];

    environment.systemPackages = [
      cfg.package.bin
      cfg.package.out
    ];

    # The polkit daemon reads action/rule files
    environment.pathsToLink = [ "/share/polkit-1" ];

    # PolKit rules for NixOS.
    environment.etc."polkit-1/rules.d/10-nixos.rules".text = ''
      polkit.addAdminRule(function(action, subject) {
        return [${lib.concatStringsSep ", " (map (i: "\"${i}\"") cfg.adminIdentities)}];
      });

      ${cfg.extraConfig}
    ''; # TODO: validation on compilation (at least against typos)

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package.out ];

    security.pam.services.polkit-1 = {
      text = ''
        # Account management.
        account required pam_unix.so # unix (order 10900)

        # Authentication management.
        auth sufficient pam_unix.so likeauth try_first_pass # unix (order 11600)
        auth required pam_deny.so # deny (order 12400)

        # Password management.
        password sufficient pam_unix.so nullok yescrypt # unix (order 10200)

        # Session management.
        session required pam_env.so conffile=/etc/security/pam_env.conf readenv=0 # env (order 10100)
        session required pam_unix.so # unix (order 10200)
        session required pam_limits.so # conf=/nix/store/mibdlp1bmk4wl2qjk77i6fl1dg4kq6k6-limits.conf # limits (order 12200)
      '';
    };

    security.wrappers = {
      pkexec = {
        setuid = true;
        owner = "root";
        group = "root";
        source = "${cfg.package.bin}/bin/pkexec";
      };
      polkit-agent-helper-1 = {
        setuid = true;
        owner = "root";
        group = "root";
        source = "${cfg.package.out}/lib/polkit-1/polkit-agent-helper-1";
      };
    };

    users.users.polkituser = {
      description = "PolKit daemon";
      uid = config.ids.uids.polkituser;
      group = "polkituser";
    };

    users.groups.polkituser = { };
  };
}
