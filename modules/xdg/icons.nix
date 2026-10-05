{
  config,
  pkgs,
  lib,
  ...
}:
{
  options.xdg.icons = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to install files to support the
        [XDG Icon Theme specification](https://specifications.freedesktop.org/icon-theme-spec/latest).

        This is what puts `/share/icons` on {option}`environment.pathsToLink`, so a machine
        with it off has profiles containing no icon themes at all, whatever was installed
        into them - a per-user profile is a `buildEnv` over that list, not a view of the
        packages. Anything resolving an icon by name, which on a desktop is most things,
        then finds nothing.
      '';
    };

    fallbackCursorThemes = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [ "Adwaita" ];
      description = ''
        Names of the fallback cursor themes, in order of preference, to be used when no
        other icon source can be found. Empty disables the fallback entirely.
      '';
    };
  };

  config = lib.mkIf config.xdg.icons.enable {
    environment.pathsToLink = [
      "/share/icons"
      "/share/pixmaps"
    ];

    environment.systemPackages = [
      # the empty theme carrying the index.theme which describes where toolkits should look
      # for icons installed by applications
      pkgs.hicolor-icon-theme
    ]
    ++ lib.optional (config.xdg.icons.fallbackCursorThemes != [ ]) (
      pkgs.writeTextFile {
        name = "fallback-cursor-theme";
        destination = "/share/icons/default/index.theme";
        text = ''
          [Icon Theme]
          Inherits=${lib.concatStringsSep "," config.xdg.icons.fallbackCursorThemes}
        '';
      }
    );

    # The cursor search path, which belongs with the icons rather than with the session
    # baseline: libXcursor looks for cursors in XCURSOR_PATH and mostly follows the icon
    # theme spec to do it, so a cursor theme is an icon theme and these are two consumers of
    # one set of directories. nixos keeps them in one module for the same reason.
    #
    # It was among `security.pam.environment`'s defaults, naming only
    # /run/current-system/sw/share/{icons,pixmaps}. That is right for a machine where
    # nothing installs into a home or a per-user profile, and wrong for every machine that
    # does - which is any machine with home-manager on it.
    #
    # Setting XCURSOR_PATH replaces libXcursor's built-in path rather than extending it, so
    # a directory left out here is not searched at all. Which is what made this look like a
    # compositor bug: a compositor asking for the configured theme found nothing and fell
    # back to its own built-in cursor, while gtk applications looked right - they read
    # gtk-cursor-theme-name from settings.ini and resolve it by another route entirely.
    #
    # `@{HOME}` and `@{PAM_USER}` are pam_env items; `$HOME` would be written through
    # literally and never expand.
    #
    # Order is the point. nixos puts the home directories first, with the comment "These are
    # preferred so they come first in the list", so a theme present in both resolves to the
    # user's.
    security.pam.environment.XCURSOR_PATH.default = [
      # written directly by home-manager's `home.pointerCursor`, and in no profile
      "@{HOME}/.icons"
      "@{HOME}/.local/share/icons"

      # both profile layouts, because `use-xdg-base-directories` decides which one nix writes
      # and nothing here can see that setting. nixos needs neither: its home-manager packages
      # reach /etc/profiles/per-user and stop there.
      "@{HOME}/.local/state/nix/profile/share/icons"
      "@{HOME}/.nix-profile/share/icons"

      "/etc/profiles/per-user/@{PAM_USER}/share/icons"
      "/etc/profiles/per-user/@{PAM_USER}/share/pixmaps"

      "/run/current-system/sw/share/icons"
      "/run/current-system/sw/share/pixmaps"
    ];
  };
}
