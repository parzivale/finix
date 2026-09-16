# how services.keventd runs, as providers.services units
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
  cfg = config.services.keventd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.keventd = {
      description = "device event daemon (keventd)";

      # a device manager belongs in the head tier, beside udev and mdevd: `sysinit` then waits
      # for it, and everything in a later tier has device events without asking.
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      # the udev cfg.rules keventd runs invoke helpers by name, so it needs a PATH. Every
      # implementation gives a unit one now - dinit's is scripted in by its backend rather
      # than declared unsupported - so this says what it wants and nothing about how.
      inherit (cfg) path;

      # read from a fixed path and named nowhere else, so a changed ruleset would
      # otherwise leave the daemon running with the old one
      restartTriggers = [ cfg.rules ];

      type.service = {
        # the cfg.rules are read from /etc/udev/cfg.rules.d, but the unit names the tree they were
        # generated from, so a changed rule is a changed unit and the daemon is restarted with
        # it. The `# reload trigger` this replaces was appended to finit.d/keventd.conf, and so
        # reached finit alone.
        command = "${config.finit.package}/libexec/finit/keventd ${lib.escapeShellArgs cfg.extraArgs}";

        # `notify = "pid"` is gone with the stanza: it asked finit to manage a pid file on the
        # daemon's behalf, which says nothing about readiness and has no equivalent elsewhere.
        # The process running is what any backend can observe, which is `fork`.
        readiness = "fork";
      };
    };
  };
}
