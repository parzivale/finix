# how services.sshguard runs, as providers.services units
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
  cfg = config.services.sshguard;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.sshguard = {
      description = "ssh brute-force guard";

      # nftables is a contract unit now, so what was a condition naming finit's own task is an
      # ordinary edge. syslogd is in the head tier and needs no naming.
      requires = [
        "basic"
        "network-online"
      ]
      ++ lib.optional (cfg.settings.BACKEND == "nft-sets") "nftables";

      # sshguard runs its backend scripts, and those run nft by name
      path = [
        config.programs.coreutils.package
      ]
      ++ lib.optional (cfg.settings.BACKEND == "nft-sets") config.services.nftables.package;

      type.service.command = lib.getExe cfg.package;

      environment = lib.optionalAttrs cfg.debug {
        SSHGUARD_DEBUG = "1";
      };
    };
  };
}
