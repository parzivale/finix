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
      # The device manager is asked to populate /dev first where there is one. Both managers
      # have a unit which triggers that - udev's coldplug, mdevd's - and both are named rather
      # than relied on through the trunk.
      #
      # The trigger and not a settle. udev used to offer one and this named it, which meant a
      # logger waited for the entire device tree to drain before it could start - about two
      # seconds on a laptop, for a dependency it does not have. /dev is devtmpfs and is mounted
      # before any unit runs, so /dev/log has somewhere to live regardless. What the ordering
      # actually buys is that a manager which is going to create nodes has started doing so.
      requires = [
        (lib.head config.providers.services.trunk.levels)

        # in the same tier, so named rather than merely attached-after: /var/log is one of the
        # base tmpfiles rules, and on a machine where it is not already on disk the logger
        # would otherwise race the unit which creates it.
        "tmpfiles-setup"
      ]
      ++ lib.optional config.services.udev.enable "udev-coldplug"
      ++ lib.optional config.services.mdevd.enable "coldplug"

      # and the thing which mounts /var/log, where there is one.
      #
      # Same race as tmpfiles-setup above and a worse outcome. If /var/log is a preserved path,
      # something bind-mounts it from disk during boot, and a logger which opened its file first
      # is writing underneath that mount: the lines go to the tmpfs the mount covers, where
      # nothing can read them and the next reboot discards them. The log of the boot you need to
      # explain is the one guaranteed to be missing.
      #
      # It cost a diagnosis to find. A machine on sinit left no trace of itself at all - forty
      # boots in the logs, none of them that one - because sinit launches every job at once and
      # orders them only by latch, so nothing serialised the two. On finit the tiers happened to.
      #
      # Named by unit rather than by option, because `preservation` is not finix's: the module
      # declaring it lives elsewhere, and asking after `config.preservation.enable` would be an
      # eval error on every machine without it. `enable` and not merely presence - a disabled unit
      # is still an attribute, and requiring one no backend will emit is how a logger waits for
      # something that never starts.
      ++ lib.optional (config.providers.services.units.preservation.enable or false) "preservation";
    };
  };
}
