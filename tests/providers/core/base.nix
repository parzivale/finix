# the machine a core test runs on, once per implementation
#
# The only thing that differs between the four instantiations is the name in
# `providers.services.backend` and the module that name refers to. Everything else is identical,
# which is what makes a difference in the result attributable to the implementation rather than
# to the configuration.
{
  backend,
  coreLib,
}:
{
  lib,
  modules,
  ...
}:
{
  # finit is in the default module set; the other three are opted into by name
  imports = lib.optional (backend != "finit") modules.${backend};

  providers.services.backend = backend;

  # a device manager, which every one of these needs and none of them has to describe: the
  # module emits contract units, so this is the same daemon on all four.
  services.mdevd.enable = true;

  # a terminal is not a daemon - no readiness signal, and nothing ever depends on one - so it is
  # not modelled as a unit. finix asserts finit.ttys is non-empty when finit is PID 1; no other
  # backend needs a terminal for these tests at all.
  services.getty.enable = false;
  finit.ttys = lib.mkIf (backend == "finit") {
    tty1 = {
      description = "getty on /dev/tty1";
      nowait = true;
    };
  };

  # the marker directory, made once before any unit runs rather than by each unit for itself.
  # 1777 because a unit running as somebody else writes here too, and `mkdir -p` from whichever
  # unit happened to be first would leave it owned by root and unwritable by them - which looks
  # exactly like the unit never having started.
  providers.services.tmpfiles.rules = [
    {
      type = "directory";
      path = coreLib.markerDir;
      mode = "1777";
    }
  ];

  providers.services.units.booted = coreLib.bootedUnit;
}
