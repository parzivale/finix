# how services.nvidia-powerd runs, as providers.services units
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
  cfg = config.services.nvidia-powerd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.nvidia-powerd = {
      description = "NVIDIA Dynamic Boost";
      requires = [ "basic" ];

      path = [ pkgs.util-linux ]; # nvidia-powerd wants lscpu

      # `restart = -1` is gone with the stanza - restarting a service which dies is what a
      # supervisor does, on all four.
      type.service.command = "${cfg.package.bin}/bin/nvidia-powerd";
    };
  };
}
