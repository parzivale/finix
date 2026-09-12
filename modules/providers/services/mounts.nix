# mounting the system's filesystems, as part of the services contract
#
# The initrd mounts what is needed to reach the root - anything with neededForBoot - and hands
# over. Everything else in `fileSystems` is stage 2's problem, and stage 2 is whatever init was
# selected. So each of them had grown its own answer, or no answer:
#
#   finit   reads /etc/fstab natively, as part of being finit
#   dinit   a bespoke `mount -a` service in modules/init/dinit
#   runit   nothing
#   s6      nothing
#
# and the failure that produces is quiet. /run/wrappers is a tmpfs declared in `fileSystems`,
# so on the two which mount nothing the setuid wrappers have nowhere to go, pam_unix has no
# unix_chkpwd to verify a password with, and every login on the machine fails with "Login
# incorrect" whatever was typed. Nothing says a filesystem is missing.
#
# `mount -a` rather than a unit per filesystem: it skips what is already mounted, so it is
# safe on finit which has done the work already, and it reads the same /etc/fstab the rest of
# the system does rather than a second description of it that could disagree.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
in
{
  options.providers.services.mountFilesystems = lib.mkOption {
    type = lib.types.bool;
    default = true;

    description = ''
      Whether to mount the filesystems in {option}`fileSystems` which the initrd did not, as
      the `mount-filesystems` unit at the head of the trunk.

      An implementation which mounts them itself before any unit runs - finit reads
      `/etc/fstab` as part of being finit - can turn this off, though leaving it on is
      harmless: `mount -a` skips what is already mounted.
    '';
  };

  config = lib.mkIf cfg.mountFilesystems {
    providers.services.units.mount-filesystems = {
      description = "mount the remaining filesystems";
      type.oneshot.command = "${lib.getExe' pkgs.util-linux "mount"} -a";

      # the head of the trunk, so that everything attached to any later level is behind the
      # filesystems it is going to want
      requires = [ (lib.head cfg.trunk.levels) ];
    };
  };
}
