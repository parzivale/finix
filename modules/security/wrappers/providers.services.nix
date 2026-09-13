# the setuid and setcap wrappers, as a providers.services unit
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it. The scripts which build the wrapper directory come
# with the unit: nothing else in the module uses them, and they are what the unit runs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.security) wrapperDir wrappers;

  parentWrapperDir = dirOf wrapperDir;

  # This is security-sensitive code, and glibc vulns happen from time to time.
  # musl is security-focused and generally more minimal, so it's a better choice here.
  # The dynamic linker is still a fairly complex piece of code, and the wrappers are
  # quite small, so linking it statically is more appropriate.
  securityWrapper =
    sourceProg:
    pkgs.pkgsStatic.callPackage ./wrapper.nix {
      inherit sourceProg;

      # glibc definitions of insecure environment variables
      #
      # We extract the single header file we need into its own derivation,
      # so that we don't have to pull full glibc sources to build wrappers.
      #
      # They're taken from pkgs.glibc so that we don't have to keep as close
      # an eye on glibc changes. Not every relevant variable is in this header,
      # so we maintain a slightly stricter list in wrapper.c itself as well.
      unsecvars = lib.overrideDerivation (pkgs.srcOnly pkgs.glibc) (
        { name, ... }:
        {
          name = "${name}-unsecvars";
          installPhase = ''
            mkdir $out
            cp sysdeps/generic/unsecvars.h $out
          '';
        }
      );
    };

  mkSetcapProgram =
    {
      program,
      capabilities,
      source,
      owner,
      group,
      permissions,
      ...
    }:
    ''
      cp ${securityWrapper source}/bin/security-wrapper "$wrapperDir/${program}"

      # Prevent races
      chmod 0000 "$wrapperDir/${program}"
      chown ${owner}:${group} "$wrapperDir/${program}"

      # Set desired capabilities on the file plus cap_setpcap so
      # the wrapper program can elevate the capabilities set on
      # its file into the Ambient set.
      ${pkgs.libcap.out}/bin/setcap "cap_setpcap,${capabilities}" "$wrapperDir/${program}"

      # Set the executable bit
      chmod ${permissions} "$wrapperDir/${program}"
    '';

  ###### Activation script for the setuid wrappers
  mkSetuidProgram =
    {
      program,
      source,
      owner,
      group,
      setuid,
      setgid,
      permissions,
      ...
    }:
    ''
      cp ${securityWrapper source}/bin/security-wrapper "$wrapperDir/${program}"

      # Prevent races
      chmod 0000 "$wrapperDir/${program}"
      chown ${owner}:${group} "$wrapperDir/${program}"

      chmod "u${if setuid then "+" else "-"}s,g${if setgid then "+" else "-"}s,${permissions}" "$wrapperDir/${program}"
    '';

  mkWrappedPrograms = builtins.map (
    opts: if opts.capabilities != "" then mkSetcapProgram opts else mkSetuidProgram opts
  ) (lib.attrValues (lib.filterAttrs (_: wrapper: wrapper.enable) wrappers));

  wrappersScript = pkgs.writeShellScript "suid-sgid-wrappers.sh" ''
    set -e

    chmod 755 "${parentWrapperDir}"

    # We want to place the tmpdirs for the wrappers to the parent dir.
    wrapperDir=$(mktemp -d -p "${parentWrapperDir}" wrappers.XXXXXXXXXX)
    chmod a+rx "$wrapperDir"

    ${lib.concatStringsSep "\n" mkWrappedPrograms}

    if [ -L ${wrapperDir} ]; then
      # Atomically replace the symlink
      # See https://axialcorps.com/2013/07/03/atomically-replacing-files-and-directories/
      old=$(readlink -f ${wrapperDir})
      if [ -e "${wrapperDir}-tmp" ]; then
        rm -rf "${wrapperDir}-tmp"
      fi
      ln -sfn "$wrapperDir" "${wrapperDir}-tmp"
      mv -T "${wrapperDir}-tmp" "${wrapperDir}"
      rm -rf "$old"
    else
      # For initial setup
      ln -s "$wrapperDir" "${wrapperDir}"
    fi
  '';
in
{
  config = {
    providers.services.units.suid-sgid-wrappers = {
      description = "create suid/sgid wrappers";

      # PATH set by the script rather than asked for as a unit property: dinit has no per-unit
      # PATH at all, so a `path` here is a warning on that backend and a script which cannot
      # find mktemp on any of them. Wrapping it needs nothing from the implementation.
      type.oneshot.command = pkgs.writeShellScript "suid-sgid-wrappers" ''
        export PATH=${lib.makeBinPath [ config.programs.coreutils.package ]}:$PATH
        exec ${wrappersScript}
      '';

      # after the mount, not merely early: /run/wrappers is a tmpfs declared in fileSystems,
      # and the script's first act is `chmod 755 /run/wrappers` under `set -e`. Attached to
      # the trunk's head it races the unit which mounts it, and when it loses it dies on that
      # chmod without saying anything.
      requires = [ "mount-filesystems" ];
    };
  };
}
