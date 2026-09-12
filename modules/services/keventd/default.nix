{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.services.keventd;

  # in the `let` rather than inline in `environment.etc`, so the unit below can name it without
  # reading it back out of `environment.etc` - which is where most implementations put the unit
  # itself, making it a definition in terms of itself
  rules =
    pkgs.runCommand "keventd-rules"
      {
        __structuredAttrs = true;
        preferLocalBuild = true;
        allowSubstitutes = false;
        packages = lib.unique config.services.udev.packages;
      }
      ''
        mkdir -p $out
        shopt -s nullglob

        for i in "''${packages[@]}"; do
          echo "Adding rules for package $i"
          for j in $i/{etc,lib,var/lib}/udev/rules.d/*; do
            echo "Copying $j to $out/$(basename $j)"
            cat $j > $out/$(basename $j)
          done
        done

        for i in $out/*.rules; do
          substituteInPlace $i \
            --replace-quiet \"/sbin/modprobe \"${lib.getExe' pkgs.kmod "modprobe"} \
            --replace-quiet \"/sbin/mdadm \"${pkgs.mdadm}/sbin/mdadm \
            --replace-quiet \"/sbin/blkid \"${pkgs.util-linux}/sbin/blkid \
            --replace-quiet \"/bin/mount \"${pkgs.util-linux}/bin/mount \
            --replace-quiet /usr/bin/readlink ${lib.getExe' config.programs.coreutils.package "readlink"} \
            --replace-quiet /usr/bin/cat ${lib.getExe' config.programs.coreutils.package "cat"} \
            --replace-quiet /usr/bin/basename ${lib.getExe' config.programs.coreutils.package "basename"} 2>/dev/null
        done
      '';
in
{
  options.services.keventd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [keventd](${pkgs.finit.meta.homepage}) as a system service.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to `keventd`.
      '';
    };

    path = lib.mkOption {
      type = with lib.types; listOf path;
      default = [ ];
      description = ''
        Packages added to the {env}`PATH` environment variable when
        executing programs from Udev rules.

        coreutils, gnu{sed,grep}, util-linux
        automatically included.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versionAtLeast config.finit.package.version "5.0";
        message = "finit version must be at least 5.0";
      }
    ];

    services.keventd.extraArgs = [
      "-c"
      (if cfg.debug then "-d" else "-n")
    ];

    services.keventd.path = [
      config.programs.coreutils.package
      pkgs.gnugrep
      pkgs.gnused
      pkgs.kmod
      pkgs.util-linux
    ];

    # contribute finit's bundled rules to the udev packages list.
    services.udev.packages = [ config.finit.package ];

    environment.etc."udev/rules.d".source = rules;

    providers.services.units.keventd = {
      description = "device event daemon (keventd)";

      # a device manager belongs in the head tier, beside udev and mdevd: `sysinit` then waits
      # for it, and everything in a later tier has device events without asking.
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      # the udev rules keventd runs invoke helpers by name, so it needs a PATH. Every
      # implementation gives a unit one now - dinit's is scripted in by its backend rather
      # than declared unsupported - so this says what it wants and nothing about how.
      inherit (cfg) path;

      type.service = {
        # the rules are read from /etc/udev/rules.d, but the unit names the tree they were
        # generated from, so a changed rule is a changed unit and the daemon is restarted with
        # it. The `# reload trigger` this replaces was appended to finit.d/keventd.conf, and so
        # reached finit alone.
        command = pkgs.writeShellScript "keventd" ''
          # reload trigger: ${rules}
          exec ${config.finit.package}/libexec/finit/keventd ${lib.escapeShellArgs cfg.extraArgs}
        '';

        # `notify = "pid"` is gone with the stanza: it asked finit to manage a pid file on the
        # daemon's behalf, which says nothing about readiness and has no equivalent elsewhere.
        # The process running is what any backend can observe, which is `fork`.
        readiness = "fork";
      };
    };

    # TODO: share between device managers
    system.activation.scripts.keventd = lib.mkIf config.boot.kernel.enable {
      text = ''
        # Allow the kernel to find our firmware.
        if [ -e /sys/module/firmware_class/parameters/path ]; then
          echo -n "${config.hardware.firmware}/lib/firmware" > /sys/module/firmware_class/parameters/path
        fi
      '';
    };

    system.switch.inhibitors.device-manager = "keventd";

    # build out the default initramfs image
    boot.initrd = {
      finit.services.keventd = {
        command = "${config.finit.package}/libexec/finit/keventd -n -c";
        notify = "pid";
      };

      # minimal set of rules needed for initramfs
      contents =
        map
          (v: {
            target = "/etc/udev/rules.d/${v}.rules";
            source = "${config.finit.package}/lib/udev/rules.d/${v}.rules";
          })
          [
            "60-block"
            "60-persistent-storage"
            "60-persistent-storage-tape"
            "64-btrfs"
            "80-drivers"
          ];
    };
  };
}
