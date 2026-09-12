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
  # the device manager is a contract unit in the module itself now, so enabling it is the whole
  # of what this needs to say. It used to be reproduced here, with the module's finit stanzas
  # switched off, because the module only knew how to write stanzas.
  services.mdevd.enable = true;

  # a terminal is not a daemon: no readiness signal, and nothing ever depends on one. So it is
  # not a `providers.services` unit - modelling one there would export finit's tty stanza into
  # an abstraction the other three would have to honour - but its own provider, which finit
  # implements natively and everything else lowers to an ordinary supervised prompt. This is
  # also what satisfies finix's assertion that finit.ttys be non-empty.
  services.getty.enable = false;
  providers.ttys.devices.tty1 = {
    description = "getty on /dev/tty1";
    requires = [ ];
  };

  providers.services.backend = "finit";
}
