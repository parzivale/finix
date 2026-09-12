{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.fwupd;

  format = pkgs.formats.ini {
    listToValue = l: lib.concatStringsSep ";" (map (s: lib.generators.mkValueStringDefault { } s) l);
    mkKeyValue = lib.generators.mkKeyValueDefault { } "=";
  };
in
{
  options.services.fwupd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [fwupd](${pkgs.fwupd.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.fwupd;
      defaultText = lib.literalExpression "pkgs.fwupd";
      description = ''
        The package to use for `fwupd`.
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
      type = lib.types.submodule {
        freeformType = format.type;
        options = {
          fwupd = {
            IdleTimeout = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = ''
                Idle timeout in seconds before the daemon exits.
                Set to `0` to disable.
              '';
            };
          };
        };
      };
      default = { };
      description = ''
        `fwupd` configuration. See {manpage}`fwupd.conf(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc =
      let
        vendor = lib.genAttrs cfg.package.filesInstalledToEtc (file: {
          source = "${cfg.package}/etc/${file}";
        });

        local = {
          "fwupd/fwupd.conf" = {
            source = format.generate "fwupd.conf" cfg.settings;
            mode = "0640";
          };
        };
      in
      vendor // local;

    environment.systemPackages = [
      cfg.package
    ];

    services.dbus.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    providers.services.units.fwupd = {
      description = "firmware update daemon";

      # polkit is a sibling in this tier, so it is named; a tier says nothing about what sits
      # beside it. Optional because the unit only exists when the module is on, and an edge to
      # a name nothing defines is refused - fwupd runs without it, less able to authorise.
      requires = [
        "basic"
      ]
      ++ lib.optional config.services.polkit.enable "polkit";

      type.service.command =
        "${cfg.package}/libexec/fwupd/fwupd --no-timestamp" + lib.optionalString cfg.debug " --verbose";

      environment = lib.optionalAttrs (config.programs.limine.secureBoot.enable or false) {
        FWUPD_EFIAPPDIR = "${cfg.package}/libexec/fwupd/efi";
      };
    };

    providers.services.tmpfiles.rules =
      map
        (path: {
          type = "directory";
          inherit path;
        })
        [
          "/var/lib/fwupd"
          "/var/cache/fwupd"
        ];
  };
}
