# binfmt_misc: teaching the kernel to run a foreign binary by handing it to an interpreter.
#
# The kernel side is a pseudo-filesystem with a `register` file: write one `:`-delimited line
# per format and the kernel will thereafter exec the named interpreter for anything matching.
# nixos does this with `systemd-binfmt.service` reading `/etc/binfmt.d/*.conf`; the same lines
# are written here by a oneshot, since a registration is a thing done once at boot and not a
# process to supervise.
#
# The `/run/binfmt/<name>` indirection is not decoration. The kernel stores the interpreter
# path in a fixed 127-byte field, which a store path plus a binary name will exceed, so the
# registered path is a short symlink into the store. It also matters for `fixBinary`, where
# the kernel opens the interpreter at registration time and holds that file forever - the
# symlink is resolved then, so the store path it pointed at is what gets pinned.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.boot.binfmt;

  registrationLine =
    name:
    {
      recognitionType,
      offset,
      magicOrExtension,
      mask,
      preserveArgvZero,
      openBinary,
      matchCredentials,
      fixBinary,
      ...
    }:
    let
      type = if recognitionType == "magic" then "M" else "E";
      flags =
        if !(matchCredentials -> openBinary) then
          throw "boot.binfmt.registrations.${name}: openBinary = false is not possible with matchCredentials = true."
        else
          lib.optionalString preserveArgvZero "P"
          + lib.optionalString (openBinary && !matchCredentials) "O"
          + lib.optionalString matchCredentials "C"
          + lib.optionalString fixBinary "F";
    in
    ":${name}:${type}:${toString offset}:${magicOrExtension}:${toString mask}:/run/binfmt/${name}:${flags}";

  interpreterPath =
    name:
    { interpreter, wrapInterpreterInShell, ... }:
    if wrapInterpreterInShell then
      pkgs.writeShellScript "${name}-interpreter" ''
        exec -- ${interpreter} "$@"
      ''
    else
      interpreter;

  register = pkgs.writeShellScript "binfmt-register" ''
    set -eu

    # Registrations survive nothing: the kernel forgets them on unmount and this script is the
    # only thing which knows them, so clearing first makes reconfiguration idempotent rather
    # than an error on every already-registered name.
    if [ -w /proc/sys/fs/binfmt_misc/status ]; then
      echo -1 > /proc/sys/fs/binfmt_misc/status
    fi

    ${pkgs.coreutils}/bin/mkdir -p /run/binfmt

    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: reg: ''
        ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg (toString (interpreterPath name reg))} /run/binfmt/${name}
        printf '%s' ${lib.escapeShellArg (registrationLine name reg)} > /proc/sys/fs/binfmt_misc/register
      '') cfg.registrations
    )}
  '';
in
{
  options.boot.binfmt = {
    registrations = lib.mkOption {
      default = { };
      description = ''
        Extra binary formats to register with the kernel, each mapping a way of recognising a
        binary onto the interpreter which should run it.

        Note that nixos' {option}`boot.binfmt.emulatedSystems` has no counterpart here: it is
        a convenience which derives qemu registrations from a list of systems, and deriving
        them is the part this module leaves to whoever wants it. A qemu interpreter named
        here works exactly as any other does.
      '';
      example = lib.literalExpression ''
        {
          fex-x86_64 = {
            interpreter = lib.getExe' pkgs.fex-headless "FEXInterpreter";
            magicOrExtension = "\\x7fELF\\x02\\x01\\x01\\x00";
            mask = "\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00";
          };
        }
      '';

      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, name, ... }:
          {
            options = {
              recognitionType = lib.mkOption {
                type = lib.types.enum [
                  "magic"
                  "extension"
                ];
                default = "magic";
                description = "Whether to recognise the binary by a magic sequence or by a filename extension.";
              };

              offset = lib.mkOption {
                type = lib.types.int;
                default = 0;
                description = "The byte offset of the magic sequence. Meaningless for an extension.";
              };

              magicOrExtension = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The magic sequence to match, or the filename extension (without its dot).

                  Written to the kernel as given, so the escapes the kernel understands -
                  `\x` for a byte, `\\` for a backslash - are the escapes to use.
                '';
              };

              mask = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  A mask applied to the candidate bytes before comparing them with
                  {option}`magicOrExtension`, so that a field which varies can be ignored.
                  `null` means every byte must match.
                '';
              };

              preserveArgvZero = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Pass the original argv[0] to the interpreter (the `P` flag).";
              };

              openBinary = lib.mkOption {
                type = lib.types.bool;
                default = config.matchCredentials;
                defaultText = lib.literalExpression "config.matchCredentials";
                description = ''
                  Open the binary and pass the descriptor to the interpreter rather than its
                  path (the `O` flag). Implied by {option}`matchCredentials`.
                '';
              };

              matchCredentials = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Launch the interpreter with the credentials the binary would have had,
                  setuid bits included (the `C` flag). Implies {option}`openBinary`.
                '';
              };

              fixBinary = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Open the interpreter at registration time and hold it open, so that the
                  format keeps working inside a mount namespace which cannot see the
                  interpreter's path (the `F` flag).
                '';
              };

              interpreter = lib.mkOption {
                type = lib.types.path;
                description = ''
                  The interpreter to hand a matching binary to.

                  Reached through `/run/binfmt/${name}` rather than directly: the kernel's
                  field for this is 127 bytes, which a store path does not reliably fit in.
                '';
              };

              wrapInterpreterInShell = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether to wrap {option}`interpreter` in a shell script. Needed when it is
                  itself a script, since the kernel will not run one binfmt interpreter
                  through another. Turn it off for a real ELF binary, and for
                  {option}`fixBinary`, which needs something openable.
                '';
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf (cfg.registrations != { }) {
    boot.supportedFilesystems.binfmt_misc.enable = true;

    fileSystems."/proc/sys/fs/binfmt_misc" = {
      device = "binfmt_misc";
      fsType = "binfmt_misc";
      options = [
        "nosuid"
        "nodev"
        "noexec"
        "nofail"
      ];
    };

    providers.services.units.binfmt = {
      description = "register binary formats with the kernel";

      # sysinit, not multi-user: a format has to be registered before anything which might
      # exec a foreign binary runs, and that includes activation scripts and the rest of the
      # graph. The mount above is an fstab entry, so it is already in place by this point.
      requires = [ "sysinit" ];

      type.oneshot.command = toString register;
    };
  };
}
