{
  modules,
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sessiond;

  format = pkgs.formats.toml { };
  configFile = format.generate "sessiond.toml" cfg.settings;
in
{
  imports = [ modules.polkit ];

  options.services.sessiond = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sessiond](${pkgs.sessiond.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sessiond;
      defaultText = lib.literalExpression "pkgs.sessiond";
      description = ''
        The package to use for `sessiond`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `sessiond` configuration. See [upstream documentation](https://tangled.org/r0chd.pl/sessiond/blob/master/docs/CONFIGURATION.md)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package ];

    services.polkit.enable = true;

    services.sessiond.settings.power = {
      reboot = lib.mkDefault [ "/run/current-system/sw/bin/reboot" ];
      poweroff = lib.mkDefault [ "/run/current-system/sw/bin/poweroff" ];
      suspend = lib.mkDefault [ "/run/current-system/sw/bin/suspend" ];
    };

    providers.services.units.sessiond = {
      description = "daemon for power management";

      # attached to `basic`, so it is in the tier which completes `multi-user` and anything
      # attached to that is after it. Without a tier a unit is in no level's dependants, so no
      # level waits for it and the trunk says nothing about when it ran.
      #
      # `dbus-socket` on top, because the bus is attached to no tier either: what this needs is
      # the socket answering, rather than the daemon merely being up, which is all the finit
      # condition it replaces could say.
      requires = [
        "basic"
        "dbus-socket"
      ];

      type.service = {
        command = "${lib.getExe' cfg.package "sessiond"} --config ${configFile} --log-target syslog";

        # sessiond speaks sd_notify, which only finit can observe here. Asking for it on a
        # backend which cannot is refused outright by the contract, so where it cannot be
        # observed the daemon is taken as ready once spawned - the same bargain mdevd makes.
        readiness =
          if lib.elem "notify" config.providers.services.supportedFeatures.readiness then
            "notify"
          else
            "fork";
      };

      # `cgroup.delegate` is gone with the stanza: it is finit's own cgroup handling, which the
      # contract does not model and no other implementation would honour.
      environment =
        if cfg.debug then
          {
            LOG_LEVEL = "debug";
          }
        else
          {
            LOG_LEVEL = lib.mkDefault "info";
          };
    };
  };
}
