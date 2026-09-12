{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sysklogd;
in
{
  imports = [ ./providers.services.nix ];

  options.services.sysklogd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sysklogd](${pkgs.sysklogd.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sysklogd;
      defaultText = lib.literalExpression "pkgs.sysklogd";
      description = ''
        The package to use for `sysklogd`.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Additional `sysklogd` configuration. See {manpage}`syslog.conf(5)`
        for additional details.
      '';
    };
  };

  # finit has explicit sysklogd support, requires `logger` to be available in `PATH`
  options.finit = lib.optionalAttrs cfg.enable {
    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            config.path = lib.optionals (config.log != false) [ cfg.package ];
          }
        )
      );
    };

    tasks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            config.path = lib.optionals (config.log != false) [ cfg.package ];
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    # finit has explicit sysklogd support, requires `logger` to be available in `PATH`
    finit.path = [
      cfg.package
    ];

    environment.etc."syslog.d/nixos.conf".text = cfg.extraConfig;
    environment.etc."syslog.conf".source =
      lib.mkDefault "${cfg.package}/share/doc/sysklogd/syslog.conf";

    system.switch.inhibitors.syslogd = config.providers.services.units.syslogd.type.service.command;
  };
}
