{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.xdg.portal;
in
{
  options.xdg.portal = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable XDG desktop portals.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.xdg-desktop-portal;
      defaultText = lib.literalExpression "pkgs.xdg-desktop-portal";
      description = ''
        The package to use for `xdg-desktop-portal`.
      '';
    };

    portals = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = ''
        List of XDG desktop portal packages to install.
      '';
    };

    config = lib.mkOption {
      # A list becomes the `;`-separated form portals.conf reads, so a caller can
      # write either and the file is right either way.
      type =
        with lib.types;
        attrsOf (
          attrsOf (coercedTo (either (listOf str) str) (x: lib.concatStringsSep ";" (lib.toList x)) str)
        );
      default = { };
      example = {
        common.default = [ "gtk" ];
        niri."org.freedesktop.impl.portal.FileChooser" = [ "termfilepickers" ];
      };
      description = ''
        Which backend implements which portal interface, as
        {manpage}`portals.conf(5)`.

        Installing a backend says it exists; this says when to use it. With one
        backend the question does not arise - with two that implement the same
        interface, `xdg-desktop-portal` picks between them by a rule nobody wants
        to depend on, so it has to be told.

        Each attribute becomes a file under
        {file}`/etc/xdg/xdg-desktop-portal`: `common` becomes
        {file}`portals.conf`, and any other name becomes
        {file}`<name>-portals.conf`, matched against `XDG_CURRENT_DESKTOP`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.dbus.packages = [ cfg.package ] ++ cfg.portals;
    environment.systemPackages = [ cfg.package ] ++ cfg.portals;

    environment.pathsToLink = [
      # Portal definitions and upstream desktop environment portal configurations.
      "/share/xdg-desktop-portal"

      # .desktop files to register fallback icon and app name.
      "/share/applications"
    ];

    # `preferred` is the only section portals.conf has, and the key is the
    # interface name - `default` standing for "any interface not named".
    environment.etc = lib.concatMapAttrs (
      desktop: conf:
      lib.optionalAttrs (conf != { }) {
        "xdg/xdg-desktop-portal/${
          lib.optionalString (desktop != "common") "${desktop}-"
        }portals.conf".text =
          lib.generators.toINI { } { preferred = conf; };
      }
    ) cfg.config;

    # TODO: environment.sessionVariables.NIX_XDG_DESKTOP_PORTAL_DIR = "/run/current-system/sw/share/xdg-desktop-portal/portals";
  };
}
