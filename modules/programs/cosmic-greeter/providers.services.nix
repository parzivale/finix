# how programs.cosmic-greeter runs, as providers.services units
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
  cfg = config.programs.cosmic-greeter;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.cosmic-greeter-daemon = {
      description = "COSMIC greeter D-Bus daemon";

      # the bus, by name: the daemon is one of its clients and does nothing useful before it
      # answers. `service/dbus/ready` was the finit spelling of the same thing.
      requires = [ "dbus" ];

      type.service = {
        command = lib.getExe' cfg.package "cosmic-greeter-daemon";

        # `notify = "none"` in the stanza this replaces, which is finit's way of saying the
        # daemon tells it nothing - so the moment it is running is all anyone knows. That is
        # `fork` here, and it is what every implementation can observe.
        readiness = [ "fork" ];
      };
    };

    # greetd waits for the greeter's own daemon, and for whatever manages seats and sessions on
    # this machine. These were `finit.services.greetd.conditions`, which reached finit alone -
    # on any other implementation greetd started whenever it liked, and a greeter with no bus
    # daemon behind it is a login prompt which cannot log anybody in.
    providers.services.units.greetd.requires = [
      "accounts-daemon"
      "cosmic-greeter-daemon"
    ]
    ++ lib.optional config.services.sessiond.enable "sessiond"
    ++ lib.optional config.services.elogind.enable "elogind"
    ++ lib.optional config.services.seatd.enable "seatd";

    providers.services.tmpfiles.rules = [
      {
        path = "/run/cosmic-greeter";
        type.directory = {
          mode = "0755";
          user = "cosmic-greeter";
          group = "cosmic-greeter";
        };
      }
      {
        path = "/var/lib/cosmic-greeter";
        type.directory = {
          mode = "0750";
          user = "cosmic-greeter";
          group = "cosmic-greeter";
        };
      }
    ];
  };
}
