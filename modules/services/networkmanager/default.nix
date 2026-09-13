{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.networkmanager;

  format = pkgs.formats.ini { };

  configFile = format.generate "00-nixos.conf" cfg.settings;

  packages = [
    cfg.package
    pkgs.wpa_supplicant
  ];
in
{
  imports = [ ./providers.services.nix ];

  options.services.networkmanager = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [networkmanager](${pkgs.networkmanager.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.networkmanager;
      defaultText = lib.literalExpression "pkgs.networkmanager";
      description = ''
        The package to use for `networkmanager`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;
        options = {
          main.rc-manager = lib.mkOption {
            type = lib.types.enum [
              "auto"
              "file"
              "netconfig"
              "none"
              "resolvconf"
              "symlink"
              "unmanaged"
            ];
            default = "symlink";
            description = ''
              Set the `resolv.conf` management mode.
            '';
          };
        };
      };
      default = { };
      description = ''
        `networkmanager` configuration. See {manpage}`NetworkManager.conf(5)`
        for additional details.
      '';
    };

    # exposed so that providers.services.nix can name it: a unit which reads this file has
    # to name it to be rebuilt when it changes, and it cannot reach it through
    # `environment.etc`, which is where implementations put the unit itself.
    configFile = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = configFile;
      description = "The generated NetworkManager configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.networkmanager.settings.main = lib.optionalAttrs config.programs.resolvconf.enable {
      # nixpkgs builds NetworkManager with a hardcoded resolvconf path, so the
      # default rc-manager=auto always selects resolvconf, even when nothing
      # has set it up, silently dropping DNS updates.
      rc-manager = lib.mkDefault "resolvconf";
    };

    boot.kernelModules = [
      "ctr"
    ];

    environment.systemPackages = packages;
    environment.etc."NetworkManager/conf.d/00-nixos.conf".source = configFile;

    services.dbus.enable = true;
    services.dbus.packages = packages;
    services.udev.packages = packages;

    users.groups = {
      networkmanager.gid = config.ids.gids.networkmanager;
    };
  };
}
