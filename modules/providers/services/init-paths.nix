# the filesystems a Linux userland expects before it starts, as `providers.services.initPaths`
# entries
#
# Written once so that a backend asking `finix-init` for one asks for the same thing as every
# other backend: `lib.getAttrs [ "/dev/pts" ... ] (import ./init-paths.nix { inherit config; })`.
# Which of them a backend asks for, and which it claims, is its own business - see the option.
{ config }:
{
  "/sys".mount = {
    device = "sys";
    fsType = "sysfs";
    options = [
      "nosuid"
      "nodev"
      "noexec"
    ];
  };

  # the controller hierarchy. An init which supervises through cgroups wants to create and
  # populate this itself, which is a claim rather than a second mount - see finit, which does.
  "/sys/fs/cgroup".mount = {
    device = "cgroup2";
    fsType = "cgroup2";
    options = [
      "nosuid"
      "nodev"
      "noexec"
    ];
  };

  "/dev".mount = {
    device = "devtmpfs";
    fsType = "devtmpfs";
    options = [ "nosuid" ];
  };

  # the pty multiplexer's own filesystem. `gid` is the tty group, which is what a pty's slave
  # side is owned by, and `mode=0620` is what makes `write` and `wall` reach a terminal
  # without making it readable by everyone logged in. `ptmxmode` is for `/dev/ptmx` itself:
  # devtmpfs provides the node, and without this the permissions on it are 0000.
  "/dev/pts".mount = {
    device = "devpts";
    fsType = "devpts";
    options = [
      "nosuid"
      "noexec"
      "gid=${toString config.ids.gids.tty}"
      "mode=0620"
      "ptmxmode=0666"
    ];
  };

  # POSIX shared memory, which is a tmpfs by convention and by every program that uses it.
  # 1777 because it is a shared namespace: anyone may create a segment, and the sticky bit is
  # what stops them removing each other's.
  "/dev/shm".mount = {
    device = "shm";
    fsType = "tmpfs";
    options = [
      "nosuid"
      "nodev"
      "mode=1777"
    ];
  };

  "/dev/mqueue".mount = {
    device = "mqueue";
    fsType = "mqueue";
    options = [
      "nosuid"
      "nodev"
      "noexec"
    ];
  };

  "/run".mount = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "nosuid"
      "nodev"
    ];
  };
}
