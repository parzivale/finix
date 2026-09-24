{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs._1password-gui;
in
{
  options.programs._1password-gui = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable the [1Password](${pkgs._1password-gui.meta.homepage}) desktop
        application.
      '';
    };

    polkitPolicyOwners = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      example = [
        "alice"
        "bob"
      ];
      description = ''
        The users allowed to integrate 1Password with polkit-based authentication - which is
        how unlocking with a fingerprint or a system password reaches the application.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs._1password-gui;
      defaultText = lib.literalExpression "pkgs._1password-gui";
      apply = package: package.override { inherit (cfg) polkitPolicyOwners; };
      description = ''
        The package to use for 1Password. {option}`polkitPolicyOwners` is applied to whatever
        is set here, the policy being generated as part of building the package.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # Fixed for the same reason as the CLI's: 1Password requires its group to be
    # numbered above 1000.
    users.groups.onepassword.gid = config.ids.gids.onepassword;

    # The browser-integration helper, which the browser extension talks to over a
    # unix socket. setgid so it can prove which side of that socket it is; not
    # setuid, which it has no use for.
    security.wrappers."1Password-BrowserSupport" = {
      source = "${cfg.package}/share/1password/1Password-BrowserSupport";
      owner = "root";
      group = "onepassword";
      setuid = false;
      setgid = true;
    };
  };
}
