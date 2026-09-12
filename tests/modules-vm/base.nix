# the machine a module test runs on, once per implementation
#
# The same idea as tests/providers/core/base.nix, and for the same reason: the only thing that
# differs between the four instantiations is which init is PID 1, so a difference in the result
# is a difference in the implementation rather than in the configuration.
#
# What it is not is the contract suite. Those tests assert what the contract promises, with the
# units written by the test itself. These enable a real module and ask whether the daemon it
# configures actually works - which is the question evaluation cannot answer, however many
# assertions it checks.
{
  backend,
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

  # a device manager, which every one of these needs and none of them has to describe
  services.mdevd.enable = true;

  # a terminal, because finix asserts one exists when finit is PID 1. Unattached to the trunk:
  # nothing here is testing login prompts, and a test whose machine stalls should still offer a
  # console to look at.
  services.getty.enable = false;
  providers.ttys.devices.tty1 = {
    description = "getty on /dev/tty1";
    requires = [ ];
  };
}
