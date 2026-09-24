{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.lact;

  format = pkgs.formats.yaml { };
in
{
  imports = [ ./providers.services.nix ];

  options.services.lact = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [lact](${pkgs.lact.meta.homepage}) as a system service,
        for monitoring, configuring and overclocking GPUs.

        On an AMD GPU, overclocking also wants the driver's overdrive mode - see
        [LACT's wiki](https://github.com/ilya-zlobintsev/LACT/wiki/Overclocking-(AMD)).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lact;
      defaultText = lib.literalExpression "pkgs.lact";
      description = ''
        The package to use for `lact`.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = format.type;
      };
      default = { };
      description = ''
        `lact` configuration, written to {file}`/etc/lact/config.yaml`. The
        readable way to arrive at a value is to leave this empty, set what you
        want in the GUI, and look at the file it wrote.

        ::: {.note}
        Setting anything here makes that file a symlink into the store, so the
        daemon can no longer write to it and the GUI can no longer change these.
        :::
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Left alone when empty, so the daemon owns the file and the GUI can write
    # it. Naming it here is what takes that away.
    environment.etc."lact/config.yaml" = lib.mkIf (cfg.settings != { }) {
      source = format.generate "lact-config.yaml" cfg.settings;
    };
  };
}
