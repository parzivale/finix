# how services.system76-scheduler runs, as providers.services units
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
  cfg = config.services.system76-scheduler;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.system76-scheduler = {
      description = "system76 scheduler";

      # the bus and its socket gate are in the head tier, so `service/dbus/ready` is behind
      # this without being named
      requires = [ "basic" ];

      type.service = {
        command = "${lib.getExe cfg.package} daemon";

        # self-contained: the daemon is asked to reload rather than signalled, so a switch
        # which only changed the config need not drop the scheduler's process assignments
        reload = "${lib.getExe cfg.package} daemon reload";
      };

      # it shells out to modprobe, and to tar and xz to read the profile database
      path = with pkgs; [
        kmod
        gnutar
        xz
      ];

      environment = {
        RUST_LOG = lib.mkIf cfg.debug "system76_scheduler=debug";
      };
    };
  };
}
