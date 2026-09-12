{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkIf
    mkOption
    types
    ;

  gidOf = name: toString config.ids.gids.${name};

  cfg = config.services.mdevd;

  # Rules for the special standalone devices to be created at boot.
  specialRules =
    let
      tty = gidOf "tty";
    in
    ''
      null      0:0 666
      zero      0:0 666
      full      0:0 666
      random    0:0 444
      urandom   0:0 444
      hwrandom  0:0 444

      ptmx        0:${tty} 666
      pty.*       0:${tty} 660
      tty         0:${tty} 666
      tty[0-9]+   0:${tty} 660

      vcsa[0-9]*  0:${tty} 660
      ttyS[0-9]*  0:${gidOf "uucp"} 660

      snd/.*      0:${gidOf "audio"} 660

      dri/.*      0:${gidOf "video"} 660
      video[0-9]+ 0:${gidOf "video"} 660
    '';

  # Insert modules for devices with a modalias.
  # Use @ prefix to run via /bin/sh on add events.
  modaliasRule = ''-$MODALIAS=.* 0:0 660 @${lib.getExe' pkgs.kmod "modprobe"} -q "$MODALIAS"'';

  # We need symlinks in /dev/disk/{by-id,by-label,by-uuid,by-partlabel,by-partuuid}
  # so we run this script for block device events.
  # Requires blkid from util-linux be on $PATH.
  #
  # Note: The by-id symlinks just use the device name as a placeholder.
  # Real unique IDs would require querying device serial numbers, etc.
  # mdevd hands this to /bin/sh with whatever environment mdevd itself was given, so it names
  # every command absolutely rather than relying on one. `path` is a contract capability dinit
  # does not have, and a unit which cannot be given a PATH must not need one - otherwise this
  # works on finit and quietly does nothing on the backend that cannot.
  devDiskScript = pkgs.writeScript "mdevd-disk.sh" ''
    #!/bin/sh
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.util-linux
      ]
    }:$PATH
    export PATH

    case "$ACTION" in
      add)
        # Create by-id symlink (using device name as placeholder ID)
        mkdir -p /dev/disk/by-id
        ln -sf "../../$MDEV" "/dev/disk/by-id/$MDEV"

        # Create by-label, by-uuid, by-partlabel and by-partuuid symlinks from blkid output
        blkid --output export "/dev/$MDEV" 2>/dev/null | while IFS='=' read -r key value; do
          case "$key" in
            LABEL)
              mkdir -p /dev/disk/by-label
              ln -sf "../../$MDEV" "/dev/disk/by-label/$value"
              ;;
            UUID)
              mkdir -p /dev/disk/by-uuid
              ln -sf "../../$MDEV" "/dev/disk/by-uuid/$value"
              ;;
            PARTLABEL)
              mkdir -p /dev/disk/by-partlabel
              ln -sf "../../$MDEV" "/dev/disk/by-partlabel/$value"
              ;;
            PARTUUID)
              mkdir -p /dev/disk/by-partuuid
              ln -sf "../../$MDEV" "/dev/disk/by-partuuid/$value"
              ;;
          esac
        done
        ;;
      remove)
        # Remove symlinks pointing to this device.
        # We scan directories instead of calling blkid since the device may already be gone.
        #
        # Guard against a fast remove+add reorder
        for dir in /dev/disk/by-id /dev/disk/by-label /dev/disk/by-uuid /dev/disk/by-partlabel /dev/disk/by-partuuid; do
          [ -d "$dir" ] || continue
          for link in "$dir"/*; do
            [ -L "$link" ] || continue
            target=$(readlink "$link")
            case "$target" in
             "../../$MDEV")
                [ -e "/dev/$MDEV" ] && continue
                rm -f "$link"
                ;;
            esac
          done
        done
        ;;
    esac
  '';

  # Use * prefix to run via /bin/sh on any action (add/remove).
  devDiskRule = "-SUBSYSTEM=block;.* 0:${gidOf "disk"} 660 *${devDiskScript}";

  # mdevd reports readiness the s6 way: it writes a newline to a descriptor the supervisor
  # hands it, named by `-D`. Which descriptor that is, is the one thing about this the contract
  # does not express - finit substitutes `%n` into the command line, and s6 always uses 3 - so
  # the daemon cannot be described without knowing which implementation is listening.
  #
  # dinit and runit cannot observe the protocol at all. There the daemon is taken as ready once
  # spawned, which is a window: mdevd opens its netlink socket a moment after being forked, and
  # coldplug triggering events into that window would lose them.
  observable = lib.elem "s6" config.providers.services.supportedFeatures.readiness;
  descriptor = if config.providers.services.backend == "finit" then "%n" else "3";

  # the rules as a store path, which is what the daemon is pointed at - not
  # `config.environment.etc."mdev.conf".source`, which is the same file reached the long way
  # round and cannot be asked for here.
  #
  # dinit and s6-rc write their unit fingerprints into /etc. So on those two, asking for an
  # entry of environment.etc from inside a unit's command is a cycle: etc needs the
  # fingerprints, the fingerprints need every command, and this command needed etc. finit keeps
  # its fingerprints elsewhere, which is the only reason this was ever expressible.
  mdevConf = pkgs.writeText "mdev.conf" config.services.mdevd.hotplugRules;
in
{
  options.services.mdevd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [mdevd](${pkgs.mdevd.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.mdevd;
      defaultText = lib.literalExpression "pkgs.mdevd";
      description = ''
        The package to use for `mdevd`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    nlgroups = lib.mkOption {
      type = with lib.types; nullOr ints.unsigned;
      default = null;
      description = ''
        After `mdevd` has handled the uevents for hotplugged devices, rebroadcast them to the netlink groups identified
        by the mask {option}`nlgroups`.

        ::: {.note}
        A value of `4` will make the daemon rebroadcast kernel uevents to `libudev-zero`.
        :::
      '';
    };

    hotplugRules = mkOption {
      type = types.lines;
      description = ''
        Mdevd rules for hotplug events.
        These rules are active after the initial `mdevd` daemon
        has coldbooted with the `services.mdevd.coldplug` rules.
      '';
    };

    coldplugRules = mkOption {
      type = types.lines;
      description = ''
        Mdeved rules for coldplug events during the initramfs stage of booting.
      '';
    };
  };

  config = mkIf cfg.enable {

    # Populate with boot rules.
    services.mdevd = {
      hotplugRules = lib.mkMerge [
        # fallthrough rules at the top
        (lib.mkOrder 250 modaliasRule)
        (lib.mkBefore devDiskRule)
        specialRules
      ];
      coldplugRules = lib.concatLines [
        modaliasRule
        specialRules
        devDiskRule
      ];
    };

    environment.etc."mdev.conf".source = mdevConf;

    # the device manager as contract units rather than finit stanzas. Written as stanzas it
    # existed only on finit: a machine running any other backend enabled this module, got
    # nothing, and booted with no device manager at all.
    providers.services.units.mdevd = {
      description = "device event daemon (mdevd)";

      requires = [ (lib.head config.providers.services.trunk.levels) ];

      type.service = {
        command =
          "${cfg.package}/bin/mdevd"
          + lib.optionalString observable " -D ${descriptor}"
          + " -F /run/current-system/firmware -f ${mdevConf}"
          + lib.optionalString (cfg.nlgroups != null) " -O ${toString cfg.nlgroups}"
          + lib.optionalString cfg.debug " -v 3";

        readiness = if observable then "s6" else "fork";
      };

      # no `path`. The stanza this replaces carried one, with a note about hijacking `env` for
      # it - but dinit cannot give a unit a PATH at all, so anything relying on one worked on
      # finit and silently did not there. Everything reachable from here names itself
      # absolutely instead: the daemon above, the modprobe in the modalias rule, and the disk
      # script, which sets its own.
    };

    providers.services.units.coldplug = {
      description = "cold plugging system";
      requires = [ "mdevd" ];
      type.oneshot.command = "${cfg.package}/bin/mdevd-coldplug" + lib.optionalString cfg.debug " -v 3";
    };

    # TODO: share between udev and mdevd
    system.activation.scripts.mdevd = lib.mkIf config.boot.kernel.enable {
      text = ''
        # The deprecated hotplug uevent helper is not used anymore
        if [ -e /proc/sys/kernel/hotplug ]; then
          echo "" > /proc/sys/kernel/hotplug
        fi

        # Allow the kernel to find our firmware.
        if [ -e /sys/module/firmware_class/parameters/path ]; then
          echo -n "${config.hardware.firmware}/lib/firmware" > /sys/module/firmware_class/parameters/path
        fi
      '';
    };

    system.switch.inhibitors.device-manager = "mdevd";

    # build out the default initramfs image
    boot.initrd = {
      path = [
        config.services.mdevd.package
        pkgs.execline
        pkgs.util-linux
      ];

      finit.services.mdevd = {
        command = "mdevd -D %n -O 2";
        notify = "s6";
      };

      finit.run.coldplug = {
        command = "mdevd-coldplug -O 2";
        conditions = "service/mdevd/ready";
        priority = 300;
      };

      contents = [
        {
          target = "/etc/mdev.conf";
          source = pkgs.writeText "mdev.conf" config.services.mdevd.coldplugRules;
        }
        {
          source = devDiskScript;
          target = "/etc/mdevd-disk.sh";
        }
      ];
    };
  };
}
