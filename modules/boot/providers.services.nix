# how the nix store is made read-only, as a providers.services unit
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  config = {
    providers.services.units.remount-nix-store = {
      description = "remount the nix store in read only mode";

      # the head of the trunk, which is `runlevels = "S"` in the contract's vocabulary: the
      # store is mounted by the initrd, so this only has to be before anything which might
      # write to it
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      type.oneshot.command = pkgs.writeShellScript "remount-nix-store" ''
        export PATH=${
          lib.makeBinPath [
            config.programs.coreutils.package
            pkgs.util-linux
          ]
        }:$PATH

        # Make /nix/store a read-only bind mount to enforce immutability of
        # the Nix store.  Note that we can't use "chown root:nixbld" here
        # because users/groups might not exist yet.
        # Silence chown/chmod to fail gracefully on a readonly filesystem
        # like squashfs.
        chown -f 0:30000 /nix/store
        chmod -f 1775 /nix/store

        # `grep` rather than `[[ =~ ]]`: everything the machine runs at boot is POSIX, and a
        # bash-only test in a script an implementation may hand to any shell is a trap
        if ! findmnt --noheadings --output OPTIONS /nix/store | grep -qE '(^|,)ro(,|$)'; then
          # not under `set -e`, and the exit status is deliberately not this unit's.
          #
          # Hardening the store is worth attempting and not worth refusing to boot over - a
          # store which cannot be bind-mounted read-only, which is any store on a filesystem
          # that will not take one, is a machine that should come up and say so. As a finit
          # task this was the behaviour by default, because nothing waited on a task; as a
          # unit everything above it in the trunk does, so the whole boot stopped here.
          if ! mount --bind /nix/store /nix/store || ! mount -o remount,ro,bind /nix/store; then
            echo "remount-nix-store: could not make /nix/store read-only; continuing" >&2
          fi
        fi
      '';
    };
  };
}
