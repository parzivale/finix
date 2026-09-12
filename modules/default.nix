let
  programModules = builtins.mapAttrs (dir: _: ./programs/${dir}) (
    builtins.removeAttrs (builtins.readDir ./programs) [
      "README.md"

      # required modules - included by default
      "coreutils"
      "modprobe"
      "plymouth"
      "resolvconf"
      "shadow"

      # deprecated, remove at some point
      "openresolv"
    ]
  );

  serviceModules = builtins.mapAttrs (dir: _: ./services/${dir}) (
    builtins.removeAttrs (builtins.readDir ./services) [
      "README.md"

      # required modules - included by default
      "dbus"
      "elogind"
      "gardendevd"
      "keventd"
      "mdevd"
      "seatd"
      "sessiond"
      "udev"
    ]
  );

  providerModules = builtins.map (value: ./providers/${value}) (
    builtins.attrNames (builtins.removeAttrs (builtins.readDir ./providers) [ "README.md" ])
  );
in
{
  default = {
    imports = [
      ./boot
      ./environment
      ./filesystems

      # deliberately not sorted under ./init: this list's order is the order the modules are
      # merged in, and list-valued options - environment.etc, PATH - keep it. Moving this entry
      # to where it sorts changes those lists, and so every store path downstream of them.
      ./init/finit

      ./fonts
      ./hardware
      ./i18n
      ./lib
      ./misc
      ./networking
      ./nixos
      ./nixpkgs
      ./programs/coreutils
      ./programs/modprobe
      ./programs/plymouth
      ./programs/resolvconf
      ./programs/shadow
      ./security
      ./services/dbus
      ./services/elogind
      ./services/gardendevd
      ./services/keventd
      ./services/mdevd
      ./services/seatd
      ./services/sessiond
      ./services/udev
      ./system/activation
      ./system/activation/specialisation.nix
      ./system/activation/switchable-system.nix
      ./system/nixos-compat.nix
      ./time
      ./users
      ./xdg
    ]
    ++ providerModules;
  };
}
// programModules
// serviceModules
// {
  # alternative providers.services implementations, imported explicitly - a system selects one
  # with providers.services.backend. finit is the one in `default` above; the rest live beside
  # it under ./init and are opted into.
  dinit = ./init/dinit;
  s6-rc = ./init/s6-rc;
  runit = ./init/runit;

  # virtualisation

  android = ./virtualisation/android.nix;
}
