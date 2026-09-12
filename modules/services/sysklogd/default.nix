{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.sysklogd;
in
{
  options.services.sysklogd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [sysklogd](${pkgs.sysklogd.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.sysklogd;
      defaultText = lib.literalExpression "pkgs.sysklogd";
      description = ''
        The package to use for `sysklogd`.
      '';
    };

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Additional `sysklogd` configuration. See {manpage}`syslog.conf(5)`
        for additional details.
      '';
    };
  };

  # finit has explicit sysklogd support, requires `logger` to be available in `PATH`
  options.finit = lib.optionalAttrs cfg.enable {
    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            config.path = lib.optionals (config.log != false) [ cfg.package ];
          }
        )
      );
    };

    tasks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            config.path = lib.optionals (config.log != false) [ cfg.package ];
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    # finit has explicit sysklogd support, requires `logger` to be available in `PATH`
    finit.path = [
      cfg.package
    ];

    providers.services.units.syslogd = {
      description = "system logging daemon";

      type.service = {
        command = "${cfg.package}/bin/syslogd -F";

        # `-F` is foreground, so ready-on-fork is the only honest answer: the process running
        # is the whole of what any backend can observe here.
        #
        # Not pidfile readiness, which is what finit's `notify = "pid"` translated to and what
        # this port first used. finit merely watches for the file, but dinit reads pidfile
        # readiness as `bgprocess` - a process which forks into the background and writes its
        # pid - and a foreground daemon never does, so dinit waits out its start timeout and
        # fails it, taking down everything behind syslogd with it.
        readiness = "fork";
      };

      # attached to the head of the trunk, so logging is up before `sysinit` is reached and
      # everything in a later tier can log. Nothing else should have to name syslogd to get
      # that, which is what the optional `requires = [ "syslogd" ]` scattered through the other
      # service modules is working around.
      #
      # The device manager comes first where there is one: /dev/log has to exist before
      # anything can log to it, and on a machine with no device nodes yet there is nothing to
      # listen on. Both managers have a unit which means "the device nodes are there" - udev's
      # settle, mdevd's coldplug - and neither is attached to a tier, so both are named.
      requires = [
        (lib.head config.providers.services.trunk.levels)
      ]
      ++ lib.optional config.services.udev.enable "udev-settle"
      ++ lib.optional config.services.mdevd.enable "coldplug";
    };

    environment.etc."syslog.d/nixos.conf".text = cfg.extraConfig;
    environment.etc."syslog.conf".source =
      lib.mkDefault "${cfg.package}/share/doc/sysklogd/syslog.conf";

    system.switch.inhibitors.syslogd = config.providers.services.units.syslogd.type.service.command;
  };
}
