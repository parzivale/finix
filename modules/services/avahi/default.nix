{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.avahi;

  mkValueString =
    v:
    if v == true then
      "yes"
    else if v == false then
      "no"
    else
      lib.generators.mkValueStringDefault { } v;

  format = pkgs.formats.ini {
    mkKeyValue = lib.generators.mkKeyValueDefault { inherit mkValueString; } "=";
    listToValue = lib.concatMapStringsSep ", " mkValueString;
  };

  configFile = format.generate "avahi-daemon.conf" cfg.settings;

  enableDbus = cfg.settings.server.enable-dbus or true;
in
{
  options.services.avahi = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [avahi](${pkgs.avahi.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.avahi;
      defaultText = lib.literalExpression "pkgs.avahi";
      description = ''
        The package to use for `avahi`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to `avahi`. See {manpage}`avahi-daemon(8)`
        for additional details.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `avahi` configuration. See {manpage}`avahi-daemon.conf(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.avahi.extraArgs = [ "--syslog" ] ++ lib.optionals cfg.debug [ "--debug" ];
    services.avahi.settings = {
      server = { };
    };

    environment.systemPackages = [ cfg.package ];

    environment.etc."avahi/avahi-daemon.conf".source = configFile;

    providers.services.units.avahi-daemon = {
      description = "avahi daemon service";

      # nothing about syslogd or the bus: both are in the head tier, with the bus's socket gate
      # beside it, so anything here is after them
      requires = [ "basic" ];

      type.service = {
        # the daemon reads /etc/avahi/avahi-daemon.conf, but the unit names the file it was
        # generated from, so that a changed configuration is a changed unit. That is what the
        # `# reload trigger` comment appended to finit.d/avahi-daemon.conf was doing, and it
        # was doing it for finit alone - everywhere else a config change left the daemon
        # running with what it read at boot.
        command = pkgs.writeShellScript "avahi-daemon" ''
          # reload trigger: ${configFile}
          exec ${
            lib.escapeShellArgs (
              [
                (lib.getExe' cfg.package "avahi-daemon")
              ]
              ++ cfg.extraArgs
            )
          }
        '';

        # and now it is a reload rather than a restart, which keeps the published records up
        reload = "${lib.getExe' cfg.package "avahi-daemon"} -r";
      };
    };

    services.dbus = lib.optionalAttrs enableDbus {
      enable = true;
      packages = [ cfg.package ];
    };

    users.users.avahi = {
      description = "avahi-daemon privilege separation user";
      home = "/var/empty";
      group = "avahi";
      isSystemUser = true;
    };

    users.groups.avahi = { };
  };
}
