{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.udev;

  # Udev has a 512-character limit for ENV{PATH}, so create a symlink
  # tree to work around this.
  udevPath = pkgs.buildEnv {
    name = "udev-path";
    paths = cfg.path;
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
    ignoreCollisions = true;
  };

  # Perform substitutions in all udev rules files.
  udevRulesFor =
    {
      name,
      udevPackages,
      udevPath,
      udev,
      binPackages,
    }:
    pkgs.runCommand name
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        packages = lib.unique (map toString udevPackages);
      }
      ''
        mkdir -p $out
        shopt -s nullglob
        set +o pipefail

        # Set a reasonable $PATH for programs called by udev rules.
        echo 'ENV{PATH}="${udevPath}/bin:${udevPath}/sbin"' > $out/00-path.rules

        # Add the udev rules from other packages.
        for i in $packages; do
          echo "Adding rules for package $i"
          for j in $i/{etc,lib,var/lib}/udev/rules.d/*; do
            echo "Copying $j to $out/$(basename $j)"
            cat $j > $out/$(basename $j)
          done
        done

        # Fix some paths in the standard udev rules.  Hacky.
        for i in $out/*.rules; do
          substituteInPlace $i \
            --replace-quiet \"/sbin/modprobe \"${lib.getExe' pkgs.kmod "modprobe"} \
            --replace-quiet \"/sbin/mdadm \"${pkgs.mdadm}/sbin/mdadm \
            --replace-quiet \"/sbin/blkid \"${pkgs.util-linux}/sbin/blkid \
            --replace-quiet \"/bin/mount \"${pkgs.util-linux}/bin/mount \
            --replace-quiet /usr/bin/readlink ${lib.getExe' config.programs.coreutils.package "readline"} \
            --replace-quiet /usr/bin/cat ${lib.getExe' config.programs.coreutils.package "cat"} \
            --replace-quiet /usr/bin/basename ${lib.getExe' config.programs.coreutils.package "basename"} 2>/dev/null
        done

        echo -n "Checking that all programs called by relative paths in udev rules exist in ${udev}/lib/udev... "
        import_progs=$(grep 'IMPORT{program}="[^/$]' $out/* |
          sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
        run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="[^/$]' |
          sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
        for i in $import_progs $run_progs; do
          if [[ ! -x ${udev}/lib/udev/$i && ! $i =~ socket:.* ]]; then
            echo "FAIL"
            echo "$i is called in udev rules but not installed by udev"
            exit 1
          fi
        done
        echo "OK"

        echo -n "Checking that all programs called by absolute paths in udev rules exist... "
        import_progs=$(grep 'IMPORT{program}="/' $out/* |
          sed -e 's/.*IMPORT{program}="\([^ "]*\)[ "].*/\1/' | uniq)
        run_progs=$(grep -v '^[[:space:]]*#' $out/* | grep 'RUN+="/' |
          sed -e 's/.*RUN+="\([^ "]*\)[ "].*/\1/' | uniq)
        for i in $import_progs $run_progs; do
          if [[ ! -x $i ]]; then
            echo "FAIL"
            echo "$i is called in udev rules but is not executable or does not exist"
            exit 1
          fi
        done
        echo "OK"

        filesToFixup="$(for i in "$out"/*; do
          # list all files referring to (/usr)/bin paths, but allow references to /bin/sh.
          grep -P -l '\B(?!\/bin\/sh\b)(\/usr)?\/bin(?:\/.*)?' "$i" || :
        done)"

        if [ -n "$filesToFixup" ]; then
          echo "Consider fixing the following udev rules:"
          echo "$filesToFixup" | while read localFile; do
            remoteFile="origin unknown"
            for i in ${toString binPackages}; do
              for j in "$i"/*/udev/rules.d/*; do
                [ -e "$out/$(basename "$j")" ] || continue
                [ "$(basename "$j")" = "$(basename "$localFile")" ] || continue
                remoteFile="originally from $j"
                break 2
              done
            done
            refs="$(
              grep -o '\B\(/usr\)\?/s\?bin/[^ "]\+' "$localFile" \
                | sed -e ':r;N;''${s/\n/ and /;br};s/\n/, /g;br'
            )"
            echo "$localFile ($remoteFile) contains references to $refs."
          done
          exit 1
        fi
      '';

  initrdUdevRules = pkgs.runCommand "initrd-udev-rules" { } ''
    mkdir -p $out/etc/udev/rules.d
    for f in 60-cdrom_id 60-persistent-storage 75-net-description 80-drivers; do # 80-net-setup-link; do
      cp ${pkgs.eudev}/var/lib/udev/rules.d/$f.rules $out/etc/udev/rules.d
    done
  '';

  udevRulesEarly = udevRulesFor {
    name = "udev-rules";
    udevPackages = [ initrdUdevRules ];
    binPackages = [ initrdUdevRules ];
    udev = pkgs.eudev;

    inherit udevPath;
  };

  hwdbBin =
    pkgs.runCommand "hwdb.bin"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
        packages = lib.unique (map toString ([ pkgs.udev ] ++ cfg.packages));
      }
      ''
        mkdir -p etc/udev/hwdb.d
        for i in $packages; do
          echo "Adding hwdb files for package $i"
          for j in $i/{etc,lib,var/lib}/udev/hwdb.d/*; do
            ln -s $j etc/udev/hwdb.d/$(basename $j)
          done
        done

        echo "Generating hwdb database..."
        # hwdb --update doesn't return error code even on errors!
        res="$(${pkgs.buildPackages.eudev}/bin/udevadm hwdb --update --root $(pwd) 2>&1)"
        echo "$res"
        [ -z "$(echo "$res" | egrep '^Error')" ]
        mv etc/udev/hwdb.bin $out
      '';
in
{
  imports = [ ./providers.services.nix ];

  options.services.udev = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [eudev](${pkgs.eudev.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      # Plain `pkgs.eudev`, which is what upstream finix takes.
      #
      # This used to carry eudev-project/eudev#290 as a fetchpatch, for the `--ready-notify=FD`
      # option it adds: the nixpkgs this was pinned to still had 3.2.14, where taking the plain
      # package meant a udevd that never reports readiness and an initrd that waits for it,
      # times out, and carries on without saying why.
      #
      # 3.2.15 released with that merged, and the pin has now moved to it, so the override had
      # to go: patch(1) found its own change already in the source and refused the build.
      #
      #   applying patch /nix/store/...-s6-readiness.patch
      #   patching file src/udev/udevd.c
      #   Reversed (or previously applied) patch detected!  Assume -R? [n]
      #   Skipping patch.
      #   6 out of 6 hunks ignored -- saving rejects to file src/udev/udevd.c.rej
      #
      # Which is the good failure: an override that is no longer needed stops the build rather
      # than quietly producing something. `strings udevd` on the plain 3.2.15 confirms what
      # replaced it - `-r --ready-notify=FD  Notify readiness via file descriptor`.
      #
      # Still needed on this branch, which is worth saying because the system unit no longer
      # asks for it: `providers.services` spawns udevd with `readiness = "fork"`, %n being a
      # finit substitution no other init has. It is the initrd's finit stanza below that still
      # passes `--ready-notify=%n` with `notify = "s6"`, so the version floor below is load
      # bearing for any host with `boot.initrd.enable`.
      default = pkgs.eudev;
      defaultText = lib.literalExpression "pkgs.eudev";
      description = ''
        The package to use for `eudev`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    packages = lib.mkOption {
      type = with lib.types; listOf path;
      default = [ ];
      description = ''
        List of packages containing {command}`udev` rules.
        All files found in
        {file}`«pkg»/etc/udev/rules.d` and
        {file}`«pkg»/lib/udev/rules.d`
        will be included.
      '';
      apply = map lib.getBin;
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
    # Upstream's, kept because it is still load bearing here: the initrd's udevd passes
    # `--ready-notify=%n`, which is 3.2.15 or newer, and an older eudev would simply not report
    # readiness rather than failing to start. Stated rather than assumed now that nothing
    # pins the version by patching it.
    assertions = [
      {
        assertion = lib.versionAtLeast cfg.package.version "3.2.15";
        message = "eudev has to be version >= 3.2.15";
      }
    ];

    # services.udev.packages = [ extraUdevRules extraHwdbFile ];
    services.udev.path = [
      config.programs.coreutils.package
      pkgs.gnused
      pkgs.gnugrep
      pkgs.util-linux
      cfg.package
    ];

    # adapted from https://github.com/troglobit/finit/blob/master/system/10-hotplug.conf.in
    # one unit rather than the five ordered `run` stanzas this was: the steps have to happen in
    # order, and inside a script that is the shell's guarantee rather than something each
    # backend has to be asked to reproduce.
    environment.etc."udev/hwdb.bin" = lib.mkIf (cfg.packages != [ ]) { source = hwdbBin; };
    environment.etc."udev/rules.d".source = udevRulesFor {
      name = "udev-rules";
      udevPackages = [ cfg.package ] ++ cfg.packages;
      binPackages = [ cfg.package ] ++ cfg.packages;
      udev = cfg.package;

      inherit udevPath;
    };

    # where does this belong?
    system.activation.scripts.udevd = lib.mkIf config.boot.kernel.enable {
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

    system.switch.inhibitors.device-manager = "udev";

    # build out the default initramfs image
    boot.initrd = {
      path = [ config.services.udev.package ];

      finit.services.udevd = {
        command = "/bin/udevd --ready-notify=%n";
        notify = "s6";
      };

      finit.run = {
        "udevadm@1" = {
          command = "udevadm settle -t 0";
          conditions = "service/udevd/ready";
          priority = 200;
        };
        "udevadm@2" = {
          command = "udevadm control --reload";
          conditions = "service/udevd/ready";
          priority = 210;
        };
        "udevadm@3" = {
          command = "udevadm trigger -c add -t devices";
          conditions = "service/udevd/ready";
          priority = 220;
        };
        "udevadm@4" = {
          command = "udevadm trigger -c add -t subsystems";
          conditions = "service/udevd/ready";
          priority = 230;
        };
        "udevadm@5" = {
          command = "udevadm settle -t 30";
          conditions = "service/udevd/ready";
          priority = 240;
        };
      };

      contents = [
        {
          target = "/etc/udev/rules.d";
          source = udevRulesEarly;
        }
        { source = "${pkgs.eudev}/lib/udev"; }
      ];
    };
  };
}
