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

      # attached to `basic`, so it runs in the tier which completes `multi-user` - and anything
      # attached to `multi-user`, a login prompt among them, is after it by the trunk rather
      # than by naming elogind. `dbus-socket` is the one edge the tier cannot supply: the bus
      # is not attached to a level, so being in a later tier says nothing about it.
      requires = [
        "basic"
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
