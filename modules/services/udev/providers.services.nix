# how services.udev runs, as providers.services units
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
  cfg = config.services.udev;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.udevd = {
      description = "device event daemon (${cfg.package.pname})";

      type.service = {
        # `--ready-notify=%n` is gone with the finit stanza: %n is finit substituting the
        # descriptor it chose, which no other init has an equivalent for. Readiness is the
        # daemon being up, and the coldplug unit below waits for it to answer rather than
        # trusting the moment it was spawned.
        command = "${cfg.package}/bin/udevd" + lib.optionalString cfg.debug " -D";
        readiness = "fork";
      };

      requires = [ (lib.head config.providers.services.trunk.levels) ];
    };

    providers.services.units.udev-settle = {
      description = "trigger coldplug events and wait for udev to finish";

      # attached to the head of the trunk as well as to udevd, so `sysinit` waits for the
      # device nodes to be there. Anything in a later tier then has them without naming this -
      # which is what the optional `udev-settle` edges in other modules were doing.
      #
      # It needs no logging of its own: udevadm reports to its supervisor, not to /dev/log.
      requires = [
        (lib.head config.providers.services.trunk.levels)
        "udevd"
      ];

      type.oneshot.command = pkgs.writeShellScript "udev-coldplug" ''
        # udevd is "ready" as soon as it has forked, which is before its control socket
        # exists. The first thing wanting to talk to it therefore waits for an answer.
        until ${cfg.package}/bin/udevadm control --reload 2>/dev/null; do
          ${lib.getExe' pkgs.coreutils "sleep"} 0.1
        done

        ${cfg.package}/bin/udevadm trigger -c add -t devices
        ${cfg.package}/bin/udevadm trigger -c add -t subsystems
        ${cfg.package}/bin/udevadm settle -t 30
      '';
    };
  };
}
