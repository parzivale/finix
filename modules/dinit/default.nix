{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dinit;

  format = pkgs.formats.keyValue { };

  envFormat = pkgs.formats.keyValue {
    mkKeyValue = k: v: "${k}=${toString v}";
  };

  # the reconciler which used to live here - enumerate, diff, rm-dep/stop/unload, reload
  # changed, start new - is now providers.services.switch, which does the same work for every
  # implementation rather than only this one. see modules/dinit/providers.services.nix for the
  # three operations this module supplies to it.
in
{
  imports = [ ./providers.services.nix ];

  options.dinit = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dinit;
      defaultText = lib.literalExpression "pkgs.dinit";
      description = ''
        The dinit package to use.
      '';
    };

    user.services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }: {
            imports = [ ./common-options.nix ];

            config.env-file = lib.mkIf (config.environment != { }) (
              envFormat.generate "${name}.env" config.environment
            );
          }
        )
      );
      default = { };
      description = ''
        An attribute set of `dinit` user level services.

        See [upstream documentation](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html) for additional details.
      '';
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }: {
            imports = [
              ./common-options.nix
              ./system-options.nix
            ];

            config.env-file = lib.mkIf (config.environment != { }) (
              envFormat.generate "${name}.env" config.environment
            );
          }
        )
      );
      default = { };
      description = ''
        An attribute set of `dinit` system level services.

        See [upstream documentation](https://davmac.org/projects/dinit/man-pages-html/dinit-service.5.html) for additional details.
      '';
    };
  };

  config = {
    environment.systemPackages = lib.mkIf (cfg.services != { } || cfg.user.services != { }) [
      cfg.package
    ];

    environment.etc =
      let
        settingsFormat = import ./format.nix { inherit pkgs lib; };
        extraAttrs = [
          "enable"
          "environment"
          "path"
          "boot"
          "default"
        ];

        userTree = lib.mapAttrs' (name: service: {
          name = "dinit.d/user/${name}";
          value.source = settingsFormat.generate name (builtins.removeAttrs service extraAttrs);
        }) (lib.filterAttrs (_: service: service.enable) cfg.user.services);

        systemTree = lib.mapAttrs' (name: service: {
          name = "dinit.d/${name}";
          value.source = settingsFormat.generate name (builtins.removeAttrs service extraAttrs);
        }) (lib.filterAttrs (_: service: service.enable) cfg.services);
      in
      userTree
      // systemTree
      // {
        "dinit.d/boot".source = settingsFormat.generate "boot" {
          type = "internal";
          "depends-on.d" = "boot.d";
          "waits-for" = [ "default" ];
        };
        "dinit.d/boot.d/.keep".text = "";
      }
      // {
        "dinit.d/default".source = settingsFormat.generate "default" {
          type = "internal";
          "waits-for.d" = "default.d";
        };
        "dinit.d/default.d/.keep".text = "";
      };

    system.activation.scripts.dinitBootD = {
      deps = [ "etc" ];
      text = ''
        boot_d="/etc/dinit.d/boot.d"
        find "$boot_d" -maxdepth 1 -type l -exec rm -f {} +
      ''
      + lib.concatMapStrings (name: "ln -sf ../${name} $boot_d/${name}\n") (
        lib.attrNames (lib.filterAttrs (_: s: s.boot) cfg.services)
      );
    };
    system.activation.scripts.dinitDefaultD = {
      deps = [ "etc" ];
      text = ''
        default_d="/etc/dinit.d/default.d"
        find "$default_d" -maxdepth 1 -type l -exec rm -f {} +
      ''
      + lib.concatMapStrings (name: "ln -sf ../${name} $default_d/${name}\n") (
        lib.attrNames (lib.filterAttrs (_: s: s.default) cfg.services)
      );
    };

    dinit.services.mount-fstab = {
      type = "scripted";
      command = "${pkgs.util-linux}/bin/mount -a";
      boot = true;
    };
  };
}
