# the base a providers.services test builds on: a machine whose daemons are contract units
#
# lives under tests/lib because the harness treats every .nix file under tests/ as a test, and
# this is a module rather than one.
#
# without it a test would enable services.mdevd and services.getty, both of which write finit
# stanzas directly - and then a regression in the contract could be masked by finit doing the
# work anyway. driving the same daemons through the contract means every test exercises the
# thing under test.
{
  pkgs,
  config,
  lib,
  ...
}:
{
  # mdevd's whole config block sits behind `mkIf cfg.enable`, so disabling the module would
  # also take away /etc/mdev.conf and its activation script - configuration, activation and
  # service definition are bundled together, and a module cannot be partly adopted from
  # outside. so it stays enabled for what it configures, and only its finit stanzas are
  # switched off, which is the shape a real migration would take.
  services.mdevd.enable = true;
  finit.services.mdevd.enable = false;
  finit.run.coldplug.enable = false;

  # a terminal is not a daemon: no readiness signal, nothing ever depends on one, and only
  # finit has a distinct tty stanza at all - on dinit and systemd a getty is an ordinary
  # service. modelling one in the contract would export a finit peculiarity into the
  # abstraction, so it is declared here as plain finit configuration, in the same category as
  # the kernel command line. this is also what satisfies finix's assertion that finit.ttys be
  # non-empty.
  services.getty.enable = false;
  finit.ttys.tty1 = {
    description = "getty on /dev/tty1";
    nowait = true;
  };

  providers.services.backend = "finit";

  providers.services.units = {
    # named device-events, not mdevd: a contract unit sharing a name with an existing finit
    # stanza silently merges with it, so naming it after the stanza it replaces would make the
    # `enable = false` above disable this unit too.
    device-events = {
      description = "device event daemon";
      requires = [ "start" ];
      type.service.readiness = "s6";
      type.service.command = "${config.services.mdevd.package}/bin/mdevd -D %n -F /run/current-system/firmware -f ${
        config.environment.etc."mdev.conf".source
      }";
      path = [
        config.programs.coreutils.package
        pkgs.execline
        pkgs.util-linux
      ];
    };

    coldplug = {
      description = "cold plugging system";
      requires = [ "device-events" ];
      type.oneshot.command = "${config.services.mdevd.package}/bin/mdevd-coldplug";
    };
  };
}
