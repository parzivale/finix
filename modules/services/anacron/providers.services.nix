# what anacron puts in place, as providers.services rules and units
#
# Separated from the module's own options and configuration so that what this module asks of
# the contract is in one place, the same way a module implementing a `providers.*` contract
# keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.anacron;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.tmpfiles.rules = [
      {
        path = "/var/spool/anacron";
        type.directory.mode = "0755";
      }
    ];
  };
}
