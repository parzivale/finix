{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.elogind;

  format = pkgs.formats.systemd { };

  # generated here rather than inline in `environment.etc`, so the unit can name them without
  # reading them back out of `environment.etc` - which is where most implementations put the
  # unit itself, making it a definition in terms of itself
  loginConf = format.generate "logind.conf" { inherit (cfg.settings) Login; };
  sleepConf = format.generate "sleep.conf" { inherit (cfg.settings) Sleep; };
in
{
  options.services.elogind = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [elogind](${pkgs.elogind.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.elogind;
      defaultText = lib.literalExpression "pkgs.elogind";
      description = ''
        The package to use for `elogind`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    settings.Login = lib.mkOption {
      type = (pkgs.formats.keyValue { }).type;
      default = { };
      description = ''
        `elogind` login manager configuration. See {manpage}`logind.conf(5)`
        for additional details.
      '';
    };

    settings.Sleep = lib.mkOption {
      type = (pkgs.formats.keyValue { }).type;
      default = { };
      description = ''
        `elogind` suspend and hibernation configuration. See {manpage}`sleep.conf(5)`
        for additional details.
      '';
    };
  };

  # a terminal waiting for elogind is stated by the getty module, which is what owns terminals
  # and knows how to say it in both lowerings - a finit condition on a tty stanza, a `requires`
  # on a contract unit. Said from here it could only be the former, so on every backend but
  # finit the ordering quietly did not exist.

  config = lib.mkIf cfg.enable {
    # `service/dbus/ready` is gone with the stanza: what this actually needed was not the bus
    # daemon being up but its socket answering, and the finit condition could only say the
    # former. The bus unit says the latter itself now - it is not ready until the socket is
    # there - so being in a later tier than it is the whole of what this needs.
    providers.services.units.elogind = {
      description = "login manager";

      # `sysinit`, beside seatd and the bus: seat and session management is infrastructure that
      # the tier above is entitled to assume, in the same way it assumes logging and device
      # nodes. Anything in a later tier - a login prompt, polkit - is then after it by the
      # trunk rather than by naming it, and naming it would have meant an optional edge, which
      # hides a requirement rather than stating it.
      #
      # Nothing about the bus either: it and its socket gate are in the head tier, and this is
      # in the one after, so it is already behind both.
      requires = [ "sysinit" ];

      type.service = {
        # the config files are named here rather than only in /etc, so that changing one is a
        # changed unit. That is what the `# reload trigger` comment appended to
        # finit.d/elogind.conf was for, and it was for finit alone.
        command = pkgs.writeShellScript "elogind" ''
          # reload triggers: ${loginConf} ${sleepConf}
          exec ${cfg.package}/libexec/elogind
        '';

        # elogind speaks sd_notify, which only finit can observe here; everywhere else it is
        # taken as ready once spawned, the same bargain sessiond and mdevd make
        readiness = [
          "notify"
          "fork"
        ];
      };

      environment = {
        SYSTEMD_LOG_TARGET = "syslog";
      }
      // lib.optionalAttrs cfg.debug {
        SYSTEMD_LOG_LEVEL = "debug";
      };
    };

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    environment.systemPackages = [ cfg.package ];

    environment.etc."elogind/logind.conf.d/00-nixos.conf".source = loginConf;
    environment.etc."elogind/sleep.conf.d/00-nixos.conf".source = sleepConf;
  };
}
