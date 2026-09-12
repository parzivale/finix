# how programs.resolvconf runs, as providers.services units
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
  cfg = config.programs.resolvconf;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.resolvconf = {
      description = "update resolv.conf from the interface records";

      # early, and before anything which resolves a name: the records are written by whatever
      # configured the interface, and this is what turns them into /etc/resolv.conf
      requires = [ "sysinit" ];

      type.oneshot.command = "${lib.getExe cfg.package} -u";
    };
  };
}
