# how programs.regreet runs, as providers.services units
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
  cfg = config.programs.regreet;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.greetd.requires = [ "accounts-daemon" ];

  };
}
