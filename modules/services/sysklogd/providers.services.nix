# how services.sysklogd runs, as providers.services units
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
  cfg = config.services.sysklogd;
in
{
  config = lib.mkIf cfg.enable {
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

        # in the same tier, so named rather than merely attached-after: /var/log is one of the
        # base tmpfiles rules, and on a machine where it is not already on disk the logger
        # would otherwise race the unit which creates it.
        "tmpfiles-setup"
      ]
      ++ lib.optional config.services.udev.enable "udev-settle"
      ++ lib.optional config.services.mdevd.enable "coldplug";
    };
  };
}
