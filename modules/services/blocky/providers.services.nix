# how services.blocky runs, as providers.services units
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
  cfg = config.services.blocky;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.blocky = {
      inherit (cfg) user group;

      description = "a dns proxy and ad-blocker for the local network";

      requires = [
        "basic"
        "network-online"
      ];

      # `caps = [ "^cap_net_bind_service" ]` was finit's own capability handling, which the
      # contract does not model - and this needs it, since it binds port 53 as a non-root user.
      # `setpriv` carries the capability into the process instead, which works on every
      # implementation rather than on the one with a `caps` stanza.
      type.service.command = pkgs.writeShellScript "blocky" ''
        exec ${lib.getExe' pkgs.util-linux "setpriv"} \
          --ambient-caps +cap_net_bind_service \
          -- ${lib.getExe cfg.package} --config ${cfg.configFile} "$@"
      '';
    };
  };
}
