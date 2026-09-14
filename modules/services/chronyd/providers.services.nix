# how services.chrony runs, as providers.services units
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
  cfg = config.services.chrony;
  notifySupport = lib.versionAtLeast cfg.package.version "4.9";

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.chronyd = {
      description = "chrony ntp daemon";
      requires = [ "basic" ];

      type.service = {
        command = "${cfg.package}/bin/chronyd " + lib.escapeShellArgs cfg.extraArgs;

        # chrony speaks the s6 protocol from 4.9, and is told which descriptor by the
        # implementation. Older builds cannot, so the list is just `fork` there - which is
        # what saying it as a list buys: the version test stays here and the question of
        # which backends can observe it does not have to be asked at all.
        readiness = lib.optional notifySupport { s6.flag = "-N"; } ++ [ "fork" ];
      };
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/lib/chrony";
        type.directory = {
          mode = "0750";
          user = "chrony";
          group = "chrony";
        };
      }
      {
        path = "/var/lib/chrony/chrony.drift";
        type.file = {
          mode = "0640";
          user = "chrony";
          group = "chrony";
        };
      }
      {
        path = "/var/lib/chrony/chrony.keys";
        type.file = {
          mode = "0640";
          user = "chrony";
          group = "chrony";
        };
      }
    ];
  };
}
