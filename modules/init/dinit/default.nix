{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.dinit;

  # whether this machine boots dinit, as opposed to importing the module only to name it
  # as `providers.services.user.backend`. The system tree in /etc/dinit.d is PID 1's and
  # nothing else reads it, so it is conditional on this; a user tree is served out of
  # /etc/dinit-user/<name> by providers.services.nix and is not.
  isSystemInit = config.providers.services.backend == "dinit";

  format = pkgs.formats.keyValue { };

  envFormat = pkgs.formats.keyValue {
    mkKeyValue = k: v: "${k}=${toString v}";
  };

  # the reconciler which used to live here - enumerate, diff, rm-dep/stop/unload, reload
  # changed, start new - is now providers.services.switch, which does the same work for every
  # implementation rather than only this one. see modules/init/dinit/providers.services.nix for the
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
      // lib.optionalAttrs isSystemInit {
        "dinit.d/boot".source = settingsFormat.generate "boot" {
          type = "internal";
          "depends-on.d" = "boot.d";
          "waits-for" = [ "default" ];
        };
        "dinit.d/boot.d/.keep".text = "";
      }
      // lib.optionalAttrs isSystemInit {
        "dinit.d/default".source = settingsFormat.generate "default" {
          type = "internal";
          "waits-for.d" = "default.d";
        };
        "dinit.d/default.d/.keep".text = "";
      };

    # Both of these, and the `boot`/`default` scaffolding above, only mean anything to a dinit
    # which is PID 1: they are how its two internal targets find the services that want to be in
    # them, and it reads them out of /etc/dinit.d. A user tree is served from
    # /etc/dinit-user/<name> by providers.services.nix instead and never looks here.
    #
    # So they are gated on the backend rather than emitted always. A machine which imports this
    # module only to name dinit as `providers.services.user.backend` - supervising a session
    # while something else is PID 1 - was getting the whole system tree regardless, and with
    # `dinit.services` empty that is two activation snippets which delete nothing from two
    # directories nothing writes to:
    #
    #   boot_d="/etc/dinit.d/boot.d"
    #   find "$boot_d" -maxdepth 1 -type l -exec rm -f {} +
    #
    # `environment.systemPackages` above already asks a question of this shape; this is the rest
    # of the block catching up with it.
    system.activation.scripts.dinitBootD = lib.mkIf isSystemInit {
      deps = [ "etc" ];
      text = ''
        boot_d="/etc/dinit.d/boot.d"
        find "$boot_d" -maxdepth 1 -type l -exec rm -f {} +
      ''
      + lib.concatMapStrings (name: "ln -sf ../${name} $boot_d/${name}\n") (
        lib.attrNames (lib.filterAttrs (_: s: s.boot) cfg.services)
      );
    };
    system.activation.scripts.dinitDefaultD = lib.mkIf isSystemInit {
      deps = [ "etc" ];
      text = ''
        default_d="/etc/dinit.d/default.d"
        find "$default_d" -maxdepth 1 -type l -exec rm -f {} +
      ''
      + lib.concatMapStrings (name: "ln -sf ../${name} $default_d/${name}\n") (
        lib.attrNames (lib.filterAttrs (_: s: s.default) cfg.services)
      );
    };

    # mounting the stage-2 filesystems used to be this bespoke service, which is why dinit was
    # the only non-finit backend on which /run/wrappers existed. It is the contract's
    # mount-filesystems unit now, so every backend gets it.
  };
}
