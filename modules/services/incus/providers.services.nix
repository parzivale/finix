# how services.incus runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.incus;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.incusd = {
      description = "incus container hypervisor";

      # the logger is behind the tier which completes `basic`
      requires = [ "basic" ];

      # a hypervisor being asked to stop has guests to stop first, and 30 seconds was finit's
      # figure for it
      stopTimeout = 30;

      type.service.command = pkgs.writeShellApplication {
        name = "incusd";
        runtimeEnv = {
          INCUS_USBIDS_PATH = "${pkgs.hwdata}/share/hwdata/usb.ids";
        };
        runtimeInputs = with pkgs; [
          cfg.package

          qemu_kvm

          acl
          attr
          bash
          btrfs-progs
          cdrkit
          config.programs.coreutils.package
          criu
          dnsmasq
          e2fsprogs
          findutils
          getent
          gnugrep
          gnused
          gnutar
          gptfdisk
          gzip
          iproute2
          iptables
          iw
          kmod
          libnvidia-container
          libxfs
          lvm2
          lxcfs
          minio
          minio-client
          nftables
          qemu-utils
          qemu_kvm
          rsync
          squashfs-tools-ng
          squashfsTools
          sshfs
          swtpm
          thin-provisioning-tools
          util-linux
          virtiofsd
          xdelta
          xz

          zfs
        ];

        # the resource limits were `rlimits` on the finit stanza; the contract does not model
        # them, because setting them is `ulimit` in the shell which is already starting this
        # and needs nothing from an implementation.
        #
        # `cgroup.settings."pids.max"` is not carried over: it is finit's own cgroup handling,
        # and the limit it lifts is one finit imposed in the first place.
        # https://github.com/NixOS/nixpkgs/blob/92e1950ebadc72d89e7da09dd54f815c454cec0e/nixos/modules/virtualisation/incus.nix#L404-L407
        text = ''
          ulimit -l unlimited
          ulimit -n 1048576
          ulimit -u unlimited

          exec ${cfg.package}/bin/incusd --group incus-admin --syslog${lib.optionalString cfg.debug " --debug"}
        '';
      };
    };
  };
}
