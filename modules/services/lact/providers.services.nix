# how services.lact runs, as providers.services units
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
  cfg = config.services.lact;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.lactd = {
      description = "LACT GPU control daemon";

      # `After=multi-user.target` in the unit lact ships.
      requires = [ "multi-user" ];

      # `Nice=-10` in that unit, which the contract has no word for, so it is
      # said to the process instead. A GPU control daemon losing the CPU is a
      # fan curve that responds late.
      #
      # `Restart=on-failure` needs nothing: a supervisor restarting a service
      # that died is what makes it a service rather than a oneshot.
      type.service.command = "${lib.getExe' pkgs.coreutils "nice"} -n -10 ${lib.getExe' cfg.package "lact"} daemon";

      # The daemon reads this from a fixed path, so without naming it here the
      # file could change while the unit stayed identical and lactd kept running
      # with what it started with.
      reloadTriggers = lib.optional (
        cfg.settings != { }
      ) config.environment.etc."lact/config.yaml".source;
    };
  };
}
