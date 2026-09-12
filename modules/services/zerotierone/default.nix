{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.zerotierone;
in
{
  options.services.zerotierone = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [zerotierone](${pkgs.zerotierone.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.zerotierone;
      defaultText = lib.literalExpression "pkgs.zerotierone";
      description = ''
        The package to use for `zerotierone`.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/zerotier-one";
      description = ''
        The directory used to store all `zerotier` data.

        ::: {.note}
        If left as the default value this directory will automatically be created on
        system activation, otherwise you are responsible for ensuring the directory exists
        with appropriate ownership and permissions before the `zerotier` service starts.
        :::
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [
      "tun"
    ];

    environment.systemPackages = [
      cfg.package
    ];

    providers.services.units.zerotierone = {
      description = "zerotier one";

      # syslogd is in the head tier and needs no naming; `net/route/default` was a finit
      # netlink condition, and `network-online` is the portable unit which means the same
      requires = [
        "basic"
        "network-online"
      ];

      type.service.command = "${cfg.package}/bin/zerotier-one ${cfg.stateDir}";
    };

    # TODO: ${cfg.stateDir}/networks.d/<JOIN> -> managed by linker
    providers.services.tmpfiles.rules = lib.optionals (cfg.stateDir == "/var/lib/zerotier-one") [
      {
        type = "directory";
        path = cfg.stateDir;
      }
    ];
  };
}
