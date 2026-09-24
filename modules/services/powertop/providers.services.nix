# how services.powertop runs, as providers.services units
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
  cfg = config.services.powertop;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.powertop = {
      description = "powertop tunings";

      # `after multi-user.target` on nixos. Tuning is something done to a
      # running system rather than something the system waits on, and nothing
      # else requires this unit.
      requires = [ "multi-user" ];

      # A oneshot's only knob is its command, so nixos' preStart and postStart
      # have no equivalent here: a machine wanting either writes a script and
      # makes that the command.
      type.oneshot.command = "${lib.getExe cfg.package} --auto-tune";

      # powertop loads msr to read turbo and C-state residency.
      path = [ pkgs.kmod ];
    };
  };
}
