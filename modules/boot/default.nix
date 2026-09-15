{
  config,
  pkgs,
  lib,
  ...
}:
{
  imports = [
    ./providers.services.nix
    ./bootspec.nix
    ./efi.nix
    ./initrd.nix
    ./kernel.nix
    ./root.nix
    ./sysctl.nix
  ];

  options.boot.init = lib.mkOption {
    type = lib.types.path;
    description = ''
      Executable run as stage-2 PID 1, symlinked as `''${config.system.build.toplevel}/init`.

      Set from {option}`providers.services.backend`, which names the init and the supervisor in
      one choice. This module deliberately has no default: naming one implementation here made
      it PID 1 whatever the contract said, which is the coupling the contract exists to remove.
    '';
  };

  config = {
    # a contract unit rather than a finit task: the store'"'"s immutability is not finit's to
    # arrange, and written as a stanza it was arranged on finit and on nothing else - a machine
    # booting dinit, runit or s6 ran with a writable /nix/store and nothing said so.
  };
}
