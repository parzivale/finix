# how services.mdevd runs, as providers.services units
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
  cfg = config.services.mdevd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.mdevd = {
      description = "device event daemon (mdevd)";

      requires = [ (lib.head config.providers.services.trunk.levels) ];

      type.service = {
        command =
          "${cfg.package}/bin/mdevd -F /run/current-system/firmware -f ${cfg.mdevConf}"
          + lib.optionalString (cfg.nlgroups != null) " -O ${toString cfg.nlgroups}"
          + lib.optionalString cfg.debug " -v 3";

        # what the daemon can do, best first. The contract takes the best of these the
        # implementation can observe; `fork` last is what makes that always resolvable.
        #
        # `-D` is all this needs to say about the s6 protocol - mdevd(8) takes `-D notif` - and
        # the implementation appends the descriptor it chose. Which one that is differs between
        # them and is none of mdevd's business: naming it here would describe a supervisor
        # rather than a daemon.
        readiness = [
          { s6.flag = "-D"; }
          "fork"
        ];
      };

      # no `path`. The stanza this replaces carried one, with a note about hijacking `env` for
      # it - but dinit cannot give a unit a PATH at all, so anything relying on one worked on
      # finit and silently did not there. Everything reachable from here names itself
      # absolutely instead: the daemon above, the modprobe in the modalias rule, and the disk
      # script, which sets its own.
    };

    providers.services.units.coldplug = {
      description = "cold plugging system";

      # attached to the head of the trunk as well as to mdevd, so `sysinit` waits for the
      # device nodes to be there and later tiers need not name this. mdevd-coldplug reports to
      # its supervisor, so it wants no logging of its own.
      requires = [
        (lib.head config.providers.services.trunk.levels)
        "mdevd"
      ];
      type.oneshot.command = "${cfg.package}/bin/mdevd-coldplug" + lib.optionalString cfg.debug " -v 3";
    };
  };
}
