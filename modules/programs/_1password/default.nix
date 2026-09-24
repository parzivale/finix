{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs._1password;
in
{
  options.programs._1password = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable the [1Password](${pkgs._1password-cli.meta.homepage}) CLI.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs._1password-cli;
      defaultText = lib.literalExpression "pkgs._1password-cli";
      description = ''
        The package to use for `op`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    # The gid is fixed rather than allocated: 1Password checks that its own
    # group is numbered above 1000 and refuses to run otherwise, so this is one
    # of the few groups whose number is part of what it is.
    users.groups.onepassword-cli.gid = config.ids.gids.onepassword-cli;

    # setgid, not setuid. `op` proves to the desktop app that its caller is the
    # binary the system installed, and group membership is what it checks - so it
    # needs the group and nothing more. Root would be strictly more than the job.
    security.wrappers.op = {
      source = "${cfg.package}/bin/op";
      owner = "root";
      group = "onepassword-cli";
      setuid = false;
      setgid = true;
    };
  };
}
