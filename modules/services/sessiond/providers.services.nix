# how services.sessiond runs, as providers.services units
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
  cfg = config.services.sessiond;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sessiond = {
      description = "daemon for power management";

      # `sysinit`, beside seatd and elogind: a session manager is the same kind of thing as a
      # seat manager, and belongs in the same tier as the rest of them, so that everything
      # above can assume it without naming it.
      #
      # Nothing about the bus either: it and its socket gate are in the head tier, and this is
      # in the one after, so it is already behind both.
      requires = [ "sysinit" ];

      type.service = {
        command = "${lib.getExe' cfg.package "sessiond"} --config ${cfg.configFile} --log-target syslog";

        # sessiond speaks sd_notify, which only finit can observe here. Asking for it on a
        # backend which cannot is refused outright by the contract, so where it cannot be
        # observed the daemon is taken as ready once spawned - the same bargain mdevd makes.
        readiness =
          if lib.elem "notify" config.providers.services.supportedFeatures.readiness then
            "notify"
          else
            "fork";
      };

      # `cgroup.delegate` is gone with the stanza: it is finit's own cgroup handling, which the
      # contract does not model and no other implementation would honour.
      environment =
        if cfg.debug then
          {
            LOG_LEVEL = "debug";
          }
        else
          {
            LOG_LEVEL = lib.mkDefault "info";
          };
    };
  };
}
