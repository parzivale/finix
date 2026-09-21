{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.limine;

  limine-install = pkgs.callPackage ../../../pkgs/limine-install { };

  limineInstallConfig = pkgs.writeText "limine-install.json" (
    builtins.toJSON {
      inherit (cfg)
        additionalFiles
        biosDevice
        biosSupport
        efiSupport
        enrollConfig
        extraEntries
        force
        partitionIndex
        settings
        validateChecksums
        secureBoot
        ;

      nixPath = config.services.nix-daemon.package;
      efiBootMgrPath = pkgs.efibootmgr;
      liminePath = cfg.package;
      efiMountPoint = config.boot.loader.efi.efiSysMountPoint;
      fileSystems = config.fileSystems;
      canTouchEfiVariables = config.boot.loader.efi.canTouchEfiVariables;
      efiRemovable = cfg.efiInstallAsRemovable;
      maxGenerations = if cfg.maxGenerations == null then 0 else cfg.maxGenerations;
      hostArchitecture = pkgs.stdenv.hostPlatform.parsed.cpu;
      fwupdEfiPath = config.services.fwupd.package or null;
    }
  );
in
{
  options.providers.bootloader.backend = lib.mkOption {
    type = lib.types.enum [ "limine" ];
  };

  config = lib.mkIf (config.providers.bootloader.backend == "limine") {
    # the toplevel the hook is called with is not needed: everything the
    # install reads comes from the config below or from the nix profiles.
    providers.bootloader.installHook = pkgs.writeShellScript "limine-install" ''
      exec ${lib.getExe limine-install} ${limineInstallConfig}
    '';
  };
}
