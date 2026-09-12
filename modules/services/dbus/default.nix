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
    providers.services.tmpfiles.rules =
      map
        (path: {
          type = "directory";
          inherit path;
          mode = "0755";
          user = "messagebus";
          group = "messagebus";
        })
        [
          "/run/dbus"
          "/run/lock/subsys"
          "/var/lib/dbus"
          "/tmp/dbus"
        ]
      ++ [
        {
          type = "symlink";
          path = "/etc/machine-id";
          argument = "/var/lib/dbus/machine-id";
        }
      ];

    # users.groups.messagebus.gid = config.ids.gids.messagebus;
    users.groups = {
      messagebus = { };
    };

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

    providers.services.units.dbus = {
      description = "d-bus message bus daemon";

      # the machine-id generation that was finit's `pre` moves into the command, which needs
      # nothing from the implementation at all.
      type.service = {
        command = pkgs.writeShellScript "dbus-daemon" ''
          ${cfg.package}/bin/dbus-uuidgen --ensure
          exec ${cfg.package}/bin/dbus-daemon --nofork --system --syslog-only
        '';

        # the bus is running well before it is listening, and a client which connects in
        # between simply fails - so neither kind here is `fork`, which would call it ready at
        # the first of those moments rather than the second.
        #
        # `notify` first, which is what this module said before the port: dbus-daemon speaks
        # sd_notify and sends READY=1 once it is listening, and finit observes that directly.
        # Dropping it for a `waitFor` everywhere would have thrown away a better answer on the
        # one implementation that can hear it - which is the mistake the list exists to
        # prevent. Where it cannot be heard the socket says the same thing, a moment later and
        # by inference.
        readiness = [
          "notify"
          { waitFor.socket.path = "/run/dbus/system_bus_socket"; }
        ];
      };

      environment = lib.optionalAttrs cfg.debug { DBUS_VERBOSE = "1"; };

      # the head tier, beside logging and the device managers. The bus is infrastructure in the
      # same sense they are: the seat and session managers want it, and everything above them
      # wants those - so putting it any later means every one of them naming it.
      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };
  };
}
