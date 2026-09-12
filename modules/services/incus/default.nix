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
  imports = [ ./providers.services.nix ];

  options.services.incus = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [incus](${pkgs.incus.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.incus-lts;
      defaultText = lib.literalExpression "pkgs.incus-lts";
      description = ''
        The package to use for `incus`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
    ];

    # https://github.com/lxc/incus/blob/f145309929f849b9951658ad2ba3b8f10cbe69d1/doc/reference/server_settings.md
    boot.kernel.sysctl = lib.mapAttrs (_: lib.mkDefault) {
      "fs.aio-max-nr" = 524288;
      "fs.inotify.max_queued_events" = 1048576;
      "fs.inotify.max_user_instances" = 1048576;
      "fs.inotify.max_user_watches" = 1048576;
      "kernel.dmesg_restrict" = 1;
      "kernel.keys.maxbytes" = 2000000;
      "kernel.keys.maxkeys" = 2000;
      "net.core.bpf_jit_limit" = 1000000000;
      "net.ipv4.neigh.default.gc_thresh3" = 8192;
      "net.ipv6.neigh.default.gc_thresh3" = 8192;
      "vm.max_map_count" = 262144;
    };

    boot.kernelModules = [
      "br_netfilter"
      "veth"
      "xt_comment"
      "xt_CHECKSUM"
      "xt_MASQUERADE"
      "vhost_vsock"
    ];

    # waiting on resolution from https://github.com/nikstur/userborn/issues/7
    users.users.root = {
      # match documented default ranges https://linuxcontainers.org/incus/docs/main/userns-idmap/#allowed-ranges
      # subUidRanges = [
      #   {
      #     startUid = 1000000;
      #     count = 1000000000;
      #   }
      # ];
      # subGidRanges = [
      #   {
      #     startGid = 1000000;
      #     count = 1000000000;
      #   }
      # ];
    };

    environment.etc.subuid.text = ''
      root:1000000:1000000000
    '';

    environment.etc.subgid.text = ''
      root:1000000:1000000000
    '';

    users.groups = {
      incus = { };
      incus-admin = { };
    };
  };
}
