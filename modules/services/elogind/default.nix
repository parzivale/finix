{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.elogind;
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
  };

  # a terminal waiting for elogind is stated by the getty module, which is what owns terminals
  # and knows how to say it in both lowerings - a finit condition on a tty stanza, a `requires`
  # on a contract unit. Said from here it could only be the former, so on every backend but
  # finit the ordering quietly did not exist.

  config = lib.mkIf cfg.enable {
    # `service/dbus/ready` is gone with the stanza: dbus is a contract unit, and what this
    # actually needed was not the daemon being up but its socket answering - which is what
    # `dbus-socket` waits for. The finit condition could only ever say the former.
    providers.services.units.elogind = {
      description = "login manager";

      # `sysinit`, beside seatd and the bus: seat and session management is infrastructure that
      # the tier above is entitled to assume, in the same way it assumes logging and device
      # nodes. Anything in a later tier - a login prompt, polkit - is then after it by the
      # trunk rather than by naming it, and naming it would have meant an optional edge, which
      # hides a requirement rather than stating it.
      #
      # `dbus-socket` is still named: the bus is a sibling here, and a tier says nothing about
      # its own members. What this needs is the socket answering, not the daemon having forked.
      requires = [
        "sysinit"
        "dbus-socket"
      ];

      # the stanza named no notification protocol, so finit called it ready once started.
      # `fork` is that, said in the contract's words.
      type.service.command = "${cfg.package}/libexec/elogind";
    };

    services.dbus.enable = true;
    services.dbus.packages = [ cfg.package ];
    services.udev.packages = [ cfg.package ];

    environment.systemPackages = [ cfg.package ];

    environment.etc."elogind/logind.conf".text = ''
      [Login]
    '';

    environment.etc."elogind/sleep.conf".text = ''
      [Sleep]
    '';
  };
}
