# how services.dbus runs, as providers.services units
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
  cfg = config.services.dbus;
in
{
  config = lib.mkIf cfg.enable {
    # users.groups.messagebus.gid = config.ids.gids.messagebus;
    users.groups = {
      messagebus = { };
    };

    providers.services.units.dbus = {
      description = "d-bus message bus daemon";

      # the machine-id generation that was finit's `pre` moves into the command, which needs
      # nothing from the implementation at all.
      type.service = {
        command = pkgs.writeShellScript "dbus-daemon" ''
          ${cfg.package}/bin/dbus-uuidgen --ensure
          exec ${cfg.package}/bin/dbus-daemon --nofork --system --syslog-only
        '';

        # the bus is running well before it is listening, and a client which connects in
        # between simply fails - so neither kind here is `fork`, which would call it ready at
        # the first of those moments rather than the second.
        #
        # `notify` first, which is what this module said before the port: dbus-daemon speaks
        # sd_notify and sends READY=1 once it is listening, and finit observes that directly.
        # Dropping it for a `waitFor` everywhere would have thrown away a better answer on the
        # one implementation that can hear it - which is the mistake the list exists to
        # prevent. Where it cannot be heard the socket says the same thing, a moment later and
        # by inference.
        readiness = [
          "notify"
          { waitFor.socket.path = "/run/dbus/system_bus_socket"; }
        ];
      };

      environment = lib.optionalAttrs cfg.debug { DBUS_VERBOSE = "1"; };

      # the head tier, beside logging and the device managers. The bus is infrastructure in the
      # same sense they are: the seat and session managers want it, and everything above them
      # wants those - so putting it any later means every one of them naming it.
      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };
  };
}
