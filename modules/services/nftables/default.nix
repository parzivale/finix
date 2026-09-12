{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.nftables;
in
{
  options.services.nftables = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [nftables](${pkgs.nftables.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nftables;
      defaultText = lib.literalExpression "pkgs.nftables";
      description = ''
        The package to use for `nftables`.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "nftables.conf" ''
        flush ruleset

        table inet filter {
        	chain input {
        		type filter hook input priority filter;
        	}
        	chain forward {
        		type filter hook forward priority filter;
        	}
        	chain output {
        		type filter hook output priority filter;
        	}
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # boot.blacklistedKernelModules = [ "ip_tables" ];

    environment.systemPackages = [ cfg.package ];

    providers.services.units.nftables = {
      description = "load the firewall ruleset";

      # `sysinit`, so the ruleset is in place before the basic tier - a machine should not be
      # reachable before its firewall is. syslogd is in the head tier and needs no naming.
      requires = [ "sysinit" ];

      type.oneshot.command = "${lib.getExe cfg.package} -f ${cfg.configFile}";
    };

    # `post` was finit's stop action, which is the shutdown side now
    providers.services.units.nftables-flush = {
      description = "flush the firewall ruleset";
      requires = [ "stopped" ];

      type.oneshot.command = pkgs.writeShellScript "nftables-flush" ''
        ${lib.getExe cfg.package} flush ruleset
      '';
    };
  };
}
