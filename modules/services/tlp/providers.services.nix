# how services.tlp runs, as providers.services units
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
  cfg = config.services.tlp;
  tlpExe = lib.getExe cfg.package;

in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.tlp-start = {
      description = "tlp system startup";

      # early, like the runlevel S this used to sit in: the power policy should be in place
      # before the machine has much running to spend power on
      requires = [ "sysinit" ];

      # three finit stanzas reduce to this one. `tlp@reload` ran `tlp start` and existed only
      # so that a changed tlp.conf would be applied - which the stanza arranged by mentioning
      # the config's store path in a comment, so that finit saw a changed stanza and re-ran it.
      #
      # The same trick, in the place the contract looks: the config path is named inside the
      # script, so a changed tlp.conf is a changed command, which is a changed unit, which a
      # switch re-runs. No second unit whose only job is to be restarted.
      type.oneshot.command = pkgs.writeShellScript "tlp-start" ''
        # named here so that a changed config is a changed command, and so a changed unit. The
        # generated file directly, never `config.environment.etc.<...>.source`: most
        # implementations lower a unit into /etc, so reading a unit's own command back out of
        # `environment.etc` defines it in terms of itself and evaluates as infinite recursion.
        # applied again whenever this changes: ${cfg.configFile}
        exec ${tlpExe} init start
      '';
    };

    providers.services.units.tlp-stop = {
      description = "tlp system shutdown";

      # `runlevels = "06"` was finit's way of saying "on the way down", and the shutdown side
      # of the trunk is what means that on every implementation
      requires = [ "stopped" ];

      type.oneshot.command = "${tlpExe} init stop";
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/tlp";
      }
    ];
  };
}
