{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.rtkit;
in
{
  options.services.rtkit = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [rtkit](${pkgs.rtkit.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.rtkit;
      defaultText = lib.literalExpression "pkgs.rtkit";
      description = ''
        The package to use for `rtkit`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    extraGroups = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = lib.literalExpression "[ config.services.seatd.group ]";
      description = ''
        A list of groups to _unconditionally_ grant access, via `polkit`, to this services offerings. Useful
        on systems without `(e)logind`. See [Using polkit with seatd](https://wiki.alpinelinux.org/wiki/Polkit#Using_polkit_with_seatd)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.dbus.packages = [ cfg.package ];

    services.polkit.enable = true;
    services.polkit.extraConfig = lib.optionalString (cfg.extraGroups != [ ]) ''
      polkit.addRule(function(action, subject) {
        if (action.id.startsWith("org.freedesktop.RealtimeKit1.")) {
          var groups = ${builtins.toJSON cfg.extraGroups};

          if (groups.some(function(group) {
            return subject.isInGroup(group);
          })) {
            return polkit.Result.YES;
          }
        }

        return polkit.Result.NOT_HANDLED;
      });
    '';

    providers.services.units.rtkit-daemon = {
      description = "RealtimeKit scheduling policy service";

      # polkit is named because it is a sibling in this tier - a tier orders a unit against
      # everything before it and says nothing about what sits beside it. `nohup` and `cgroup`
      # are gone with the stanza: finit's own process handling, which the contract does not
      # model and no other implementation would honour.
      requires = [
        "basic"
        "polkit"
      ];

      type.service.command =
        "${cfg.package}/libexec/rtkit-daemon" + lib.optionalString cfg.debug " --debug";
    };

    users.users.rtkit = {
      isSystemUser = true;
      group = "rtkit";
      description = "RealtimeKit daemon";
    };

    users.groups.rtkit = { };
  };
}
