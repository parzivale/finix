{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.chrony;

  notifySupport = lib.versionAtLeast cfg.package.version "4.9";
in
{
  imports = [ ./providers.services.nix ];

  options.services.chrony = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [chrony](${pkgs.chrony.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.chrony;
      defaultText = lib.literalExpression "pkgs.chrony";
      apply =
        package:
        if cfg.debug then
          package.overrideAttrs (o: {
            configureFlags = o.configureFlags ++ [ "--enable-debug" ];
          })
        else
          package;
      description = ''
        The package to use for `chrony`.
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
        Additional arguments to pass to `chrony`. See {manpage}`chronyd(8)`
        for additional details.
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = pkgs.writeText "chrony.conf" ''
        server 0.nixos.pool.ntp.org iburst
        server 1.nixos.pool.ntp.org iburst
        server 2.nixos.pool.ntp.org iburst
        server 3.nixos.pool.ntp.org iburst
        makestep 1.0 3
        rtcsync
        allow
        clientloglimit 100000000
        leapsectz right/UTC
        driftfile /var/lib/chrony/drift
        dumpdir /var/run/chrony
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.chrony.extraArgs = [
      "-n"
      "-u"
      "chrony"
      "-f"
      (toString cfg.configFile)
    ]
    ++ lib.optionals cfg.debug [
      "-L"
      "-1"
    ];

    # `-N %n` was here: chrony's notification flag, and finit's substitution for the descriptor
    # it chose. Only the flag is chrony's; the descriptor belongs to whichever implementation is
    # listening, and s6-rc uses 3 rather than substituting anything. So the flag is declared as
    # part of the unit's readiness below, and the descriptor is appended by the implementation.

    environment.systemPackages = [ cfg.package ];

    users.users = {
      chrony = {
        uid = config.ids.uids.chrony;
        group = "chrony";
        description = "chrony daemon user";
        home = "/var/lib/chrony";
      };
    };

    users.groups = {
      chrony.gid = config.ids.gids.chrony;
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/chrony";
        mode = "0750";
        user = "chrony";
        group = "chrony";
      }
      {
        type = "file";
        path = "/var/lib/chrony/chrony.drift";
        mode = "0640";
        user = "chrony";
        group = "chrony";
      }
      {
        type = "file";
        path = "/var/lib/chrony/chrony.keys";
        mode = "0640";
        user = "chrony";
        group = "chrony";
      }
    ];
  };
}
