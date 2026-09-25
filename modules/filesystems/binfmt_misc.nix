{ lib, ... }:
{
  options = {
    boot.supportedFilesystems.binfmt_misc = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable support for the `binfmt_misc` filesystem.

          Not storage: it is the kernel's interface for registering a binary format against an
          interpreter, and mounting it is how those registrations become writable. See
          {option}`boot.binfmt.registrations`.
        '';
      };
    };
  };
}
