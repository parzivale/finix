{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.gnome-keyring;
in
{
  options.programs.gnome-keyring.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Whether to enable [gnome-keyring](${pkgs.gnome-keyring.meta.homepage}).
    '';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.gnome-keyring ];

    services.dbus.packages = [
      pkgs.gnome-keyring

      # `gcr_3`, not `gcr`: the plain attribute is a `throw` in aliases.nix again -
      # "removed from nixpkgs, use a `gcr_*` attribute with an explicit ABI version" -
      # which is the opposite of what it was when this line last changed, and stopped
      # the module evaluating a second time. `gcr_3` is what nixos' own gnome-keyring
      # module names, and the prompter's service file is what is wanted here: gcr owns
      # `org.gnome.keyring.SystemPrompter`.
      pkgs.gcr_3
    ];

    xdg.portal.portals = [
      pkgs.gnome-keyring
    ];

    security.wrappers.gnome-keyring-daemon = {
      owner = "root";
      group = "root";
      capabilities = "cap_ipc_lock=ep";
      source = "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon";
    };
  };
}
