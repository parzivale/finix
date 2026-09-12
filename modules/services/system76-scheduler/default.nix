{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.system76-scheduler;
in
{
  options.services.system76-scheduler = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [system76-scheduler](${pkgs.system76-scheduler.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.system76-scheduler;
      defaultText = lib.literalExpression "pkgs.system76-scheduler";
      description = ''
        The package to use for `system76-scheduler`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the `system76-scheduler` configuration file.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."system76-scheduler/config.kdl".source = cfg.configFile;
    environment.systemPackages = [ cfg.package ];

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package ];

    providers.services.units.system76-scheduler = {
      description = "system76 scheduler";

      # the bus and its socket gate are in the head tier, so `service/dbus/ready` is behind
      # this without being named
      requires = [ "basic" ];

      type.service = {
        command = "${lib.getExe cfg.package} daemon";

        # self-contained: the daemon is asked to reload rather than signalled, so a switch
        # which only changed the config need not drop the scheduler's process assignments
        reload = "${lib.getExe cfg.package} daemon reload";
      };

      # it shells out to modprobe, and to tar and xz to read the profile database
      path = with pkgs; [
        kmod
        gnutar
        xz
      ];

      environment = {
        RUST_LOG = lib.mkIf cfg.debug "system76_scheduler=debug";
      };
    };
  };
}
