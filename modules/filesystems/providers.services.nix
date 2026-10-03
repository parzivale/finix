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
  plainSwapDevices = lib.filter (sw: !isEncryptedSwap sw) config.swapDevices;

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
    providers.services.units = lib.mkMerge [
      (lib.listToAttrs (lib.map makeEncryptedSwapTask encryptedSwapDevices))

      # the plain swap devices, which fstab lists and nothing was turning on.
      #
      # `mount -a` mounts filesystems; swap is `swapon -a`'s business and it was nobody's. So a
      # configuration naming a swapfile got an fstab line, a file on disk, and no swap - which
      # is the worst of the three outcomes, because `swapDevices` reads as having worked. On
      # this machine that was 24G sitting unused while a parallel build exhausted 16G of RAM and
      # 8G of zram, and zram cannot stand in for a disk: its pages live in the memory being
      # competed for, so filling it turns a shortage into a livelock rather than a slowdown.
      #
      # finix had the other two cases already - zram has its own unit, and random-encrypted swap
      # has one per device because its /dev/mapper node is new on every boot. This is the
      # ordinary one.
      #
      # Its own unit rather than a line in `mount-filesystems`, because a failed oneshot holds
      # its dependents: a swapfile that was never `mkswap`'d would otherwise stop the boot over
      # swap, which nothing needs to be ready. Alone, it fails alone.
      #
      # After `mount-filesystems` because the swapfile lives on a filesystem that has to be
      # mounted first - /persistent, here - and `swapon -a` reads the same fstab that unit just
      # acted on.
      (lib.mkIf (plainSwapDevices != [ ]) {
        swap = {
          description = "swap devices from fstab";
          requires = [ "mount-filesystems" ];
          # tolerant, because the contract attaches this to a level and a failed oneshot holds
          # its dependants - so a swapfile that was never `mkswap`'d, or one btrfs refuses
          # because it was made without `nocow`, would stop the boot. A machine with no swap
          # boots fine; a machine that will not boot because of swap is a worse outcome than
          # the thing being reported. So it says so and carries on.
          type.oneshot.command = toString (
            pkgs.writeShellScript "swapon-fstab" ''
              if ! ${pkgs.util-linuxMinimal}/bin/swapon -a; then
                echo "swap: swapon -a failed; continuing without the fstab swap devices" >&2
              fi
            ''
          );
        };
      })
    ];
  };
}
