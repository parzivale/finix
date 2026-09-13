{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.dbus;

  homeDir = "/run/dbus";

  configDir = pkgs.makeDBusConf.override {
    suidHelper = "${config.security.wrapperDir}/dbus-daemon-launch-helper";
    serviceDirectories = cfg.packages;
  };

  inherit (lib) mkOption mkIf types;
in
{
  imports = [ ./providers.services.nix ];

  options.services.dbus = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable [dbus](${pkgs.dbus.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dbus;
      defaultText = lib.literalExpression "pkgs.dbus";
      apply =
        package:
        if cfg.debug then
          package.overrideAttrs (o: {
            mesonFlags = o.mesonFlags ++ [ "-Dverbose_mode=true" ];
          })
        else
          package;
      description = ''
        The package to use for `dbus`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    packages = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        Packages whose D-Bus configuration files should be included in
        the configuration of the D-Bus system-wide or session-wide
        message bus.  Specifically, files in the following directories
        will be included into their respective DBus configuration paths:
        {file}`«pkg»/etc/dbus-1/system.d`
        {file}`«pkg»/share/dbus-1/system.d`
        {file}`«pkg»/share/dbus-1/system-services`
        {file}`«pkg»/etc/dbus-1/session.d`
        {file}`«pkg»/share/dbus-1/session.d`
        {file}`«pkg»/share/dbus-1/services`
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.etc."dbus-1".source = configDir;

    environment.pathsToLink = [
      "/etc/dbus-1"
      "/share/dbus-1"
    ];

    users.users = {
      messagebus = {
        # uid = config.ids.uids.messagebus;
        description = "D-Bus system message bus daemon user";
        home = homeDir;
        # homeMode = "0755";
        group = "messagebus";
      };
    };

    # the contract's rules, not finit's: the unit below moved, and the directories it needs
    # have to move with it. Left behind, dbus starts on any other init and immediately fails
    # to bind a socket in a directory nobody created.
    # Install dbus for dbus tools even when using dbus-broker
    environment.systemPackages = [
      cfg.package
    ];

    services.dbus.packages = [
      cfg.package
      config.environment.path
    ];

    security.wrappers.dbus-daemon-launch-helper = {
      source = "${cfg.package}/libexec/dbus-daemon-launch-helper";
      owner = "root";
      group = "messagebus";
      setuid = true;
      setgid = false;
      permissions = "u+rx,g+rx,o-rx";
    };

  };
}
