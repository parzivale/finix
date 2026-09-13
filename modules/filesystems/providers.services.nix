# encrypted swap devices, as providers.services units
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
let
  # the swap devices which cannot be fstab lines: a random-encrypted swap is a fresh
  # /dev/mapper/<name> with a brand new key on every boot, so it is set up imperatively. These
  # three are restated here rather than shared with default.nix - they are two filters and a
  # name, and a `let` cannot cross a module boundary.
  isEncryptedSwap = sw: sw.randomEncryption.enable;
  encryptedSwapDevices = lib.filter isEncryptedSwap config.swapDevices;

  sanitizeName = s: lib.replaceStrings [ "/" " " ] [ "-" "-" ] (lib.removePrefix "/" s);

  makeEncryptedSwapTask =
    sw:
    let
      name = "cryptswap-${sanitizeName sw.device}";
    in
    {
      inherit name;
      value =
        let
          re = sw.randomEncryption;
          options =
            sw.options
            ++ lib.optional (sw.priority != null) "pri=${toString sw.priority}"
            ++ lib.optional (sw.discardPolicy != null) (
              if sw.discardPolicy == "both" then "discard" else "discard=${sw.discardPolicy}"
            );
        in
        {
          description = "Encrypted swap device on ${sw.device}";

          # `runlevels = "S"` was finit's earliest; here that is the tier after the device
          # managers, which is what has to have run before there is a device to encrypt
          requires = [ "sysinit" ];

          type.oneshot.command = toString (
            pkgs.writeShellScript name ''
              set -eu
              ${pkgs.cryptsetup}/bin/cryptsetup plainOpen \
                -c ${lib.escapeShellArg re.cipher} \
                -s ${toString re.keySize} \
                ${lib.optionalString (re.sectorSize != 0) "--sector-size ${toString re.sectorSize}"} \
                ${lib.optionalString re.allowDiscards "--allow-discards"} \
                -d ${lib.escapeShellArg re.source} \
                ${lib.escapeShellArg sw.device} ${lib.escapeShellArg name}
              ${pkgs.util-linuxMinimal}/bin/mkswap /dev/mapper/${name}
              ${pkgs.util-linuxMinimal}/bin/swapon -o ${lib.escapeShellArg (lib.concatStringsSep "," options)} /dev/mapper/${name}
            ''
          );
        };
    };
in
{
  config = {
    providers.services.units = lib.listToAttrs (lib.map makeEncryptedSwapTask encryptedSwapDevices);
  };
}
