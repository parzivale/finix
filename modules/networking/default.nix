{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.networking;

  hostidFile = pkgs.runCommand "gen-hostid" { preferLocalBuild = true; } ''
    hi="${cfg.hostId}"
    ${
      if pkgs.stdenv.hostPlatform.isBigEndian then
        ''
          echo -ne "\x''${hi:0:2}\x''${hi:2:2}\x''${hi:4:2}\x''${hi:6:2}" > $out
        ''
      else
        ''
          echo -ne "\x''${hi:6:2}\x''${hi:4:2}\x''${hi:2:2}\x''${hi:0:2}" > $out
        ''
    }
  '';
in
{
  options.networking = {
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "finix";
      description = ''
        The hostname of this system.
      '';
    };

    hostId = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "4e98920d";
      description = ''
        The 32-bit host ID of the machine, formatted as 8 hexadecimal characters.

        You should try to make this ID unique among your machines. You can
        generate a random 32-bit ID using the following commands:

        `head -c 8 /etc/machine-id`

        (this derives it from the machine-id that systemd generates) or

        `head -c4 /dev/urandom | od -A none -t x4`

        The primary use case is to ensure when using ZFS that a pool isn't imported
        accidentally on a wrong machine.
      '';
    };

    hosts = lib.mkOption {
      type = with lib.types; attrsOf (listOf str);
      example = lib.literalExpression ''
        {
          "127.0.0.1" = [ "foo.bar.baz" ];
          "192.168.0.2" = [ "fileserver.local" "nameserver.local" ];
        };
      '';
      description = ''
        Locally defined maps of IP addresses to hostnames.
      '';
    };
  };

  config = {
    assertions =
      let
        hexChars = lib.stringToCharacters "0123456789abcdef";
        isHexString = s: lib.all (c: lib.elem c hexChars) (lib.stringToCharacters (lib.toLower s));
      in
      [
        {
          assertion = cfg.hostId == null || (lib.stringLength cfg.hostId == 8 && isHexString cfg.hostId);
          message = "Invalid value given to the networking.hostId option.";
        }
      ];

    boot.kernel.sysctl = {
      # allow all users to do ICMP echo requests (ping)
      "net.ipv4.ping_group_range" = lib.mkDefault "0 2147483647";

      # Generate link-local addresses.
      "net.ipv6.conf.all.addr_gen_mode" = lib.mkDefault 3;
    };

    networking.hosts = {
      "127.0.0.1" = [ "localhost" ];
      "::1" = [ "localhost" ];
      "127.0.0.2" = [ config.networking.hostName ];
    };

    boot.initrd = {
      contents = lib.optionals (cfg.hostId != null) [
        {
          target = "/etc/hostid";
          source = hostidFile;
        }
      ];
    };

    # writing /etc/hostname is not the same as having that hostname: something has to call
    # sethostname(2) with it. finit does that itself as part of being finit, which is why this
    # was never needed before - on any other init the machine comes up as "noname" with the
    # right value sitting in a file nobody read.
    providers.services.units.set-hostname = {
      description = "apply the configured hostname";
      type.oneshot.command = "${lib.getExe' pkgs.nettools "hostname"} -F /etc/hostname";

      # early, so that anything logging or announcing itself later says the right name
      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };

    # "the machine can reach the network", as a unit rather than as a condition.
    #
    # `net/route/default` is a finit netlink condition, and seven modules were waiting on one.
    # Nothing else has netlink conditions, so the portable form of the same question is a unit
    # which does not complete until the kernel has a default route - anything which needs the
    # network requires this, on every implementation.
    #
    # Bounded, and deliberately: an unsatisfied finit condition meant the service never started
    # and the boot carried on, but a unit is something its dependants wait for. A machine with
    # no network would otherwise hold them for as long as it stayed up, where before it simply
    # ran without them.
    #
    # Bounded at five seconds and not thirty, which is what it was first written as. Nothing in
    # the trunk is exempt from being waited for: this attaches to `sysinit`, so `basic` waits
    # for it, and so does every level above - which meant that on a machine with no default
    # route, and that includes every test VM, the console appeared half a minute after the
    # machine was otherwise up. Five seconds covers a DHCP lease on a network which is there;
    # a daemon whose network arrives later has to cope with that anyway, since nothing
    # guarantees the route stays up once it has been seen.
    providers.services.units.network-online = {
      description = "wait for a default route";
      requires = [ "sysinit" ];

      type.oneshot.command = pkgs.writeShellScript "network-online" ''
        for _ in $(${lib.getExe' pkgs.coreutils "seq"} 1 50); do
          if [ -s /proc/net/route ] && ${lib.getExe' pkgs.gnugrep "grep"} -qE '^[^	]+	00000000	' /proc/net/route; then
            exit 0
          fi
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        echo "network-online: no default route after 5s, continuing" >&2
      '';
    };

    environment.etc = {
      hostname.text = cfg.hostName + "\n";

      hosts.text =
        let
          oneToString = set: ip: ip + " " + lib.concatStringsSep " " set.${ip} + "\n";
          allToString = set: lib.concatMapStrings (oneToString set) (lib.attrNames set);
        in
        allToString (lib.filterAttrs (_: v: v != [ ]) cfg.hosts);

      # /etc/services: TCP/UDP port assignments.
      services.source = pkgs.iana-etc + "/etc/services";

      # /etc/protocols: IP protocol numbers.
      protocols.source = pkgs.iana-etc + "/etc/protocols";

      # /etc/netgroup: Network-wide groups.
      netgroup.text = lib.mkDefault "";

      # /etc/host.conf: resolver configuration file
      "host.conf".text = ''
        multi on
      '';

      hostid = lib.mkIf (cfg.hostId != null) { source = hostidFile; };
    }
    // lib.optionalAttrs (pkgs.stdenv.hostPlatform.libc == "glibc") {
      # /etc/rpc: RPC program numbers.
      rpc.source = pkgs.stdenv.cc.libc.out + "/etc/rpc";
    };
  };
}
