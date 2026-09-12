{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.tzupdate;
in
{
  options.services.tzupdate = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [tzupdate](${pkgs.tzupdate.meta.homepage}) as a system task.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tzupdate;
      defaultText = lib.literalExpression "pkgs.tzupdate";
      description = ''
        The package to use for `tzupdate`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    time.timeZone = null;

    providers.services.units.tzupdate = {
      description = "timezone update service";

      # it asks the network where it is, so it waits for one. syslogd is in the head tier and
      # needs no naming.
      requires = [
        "basic"
        "network-online"
      ];

      type.oneshot.command = "${cfg.package}/bin/tzupdate -z ${pkgs.tzdata}/share/zoneinfo -d /dev/null";

      environment = {
        RUST_LOG = lib.mkIf cfg.debug "debug";
      };
    };
  };
}
