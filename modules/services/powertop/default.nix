{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.powertop;
in
{
  imports = [ ./providers.services.nix ];

  options.services.powertop = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run [powertop](${pkgs.powertop.meta.homepage})'s auto-tuning
        once at startup, applying its suggested power savings - runtime PM,
        SATA link power management, USB autosuspend, and so on.

        Some of what it tunes is not safe on every machine: autosuspend on a
        device whose firmware mishandles it, or ASPM on a link that does not
        tolerate it, shows up as a wedged device or a hard lock rather than as
        an error. Leave it off on a machine where that has happened.

        nixos spells this `powerManagement.powertop.enable`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.powertop;
      defaultText = lib.literalExpression "pkgs.powertop";
      description = ''
        The package to use for `powertop`.
      '';
    };
  };
}
