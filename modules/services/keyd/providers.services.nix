# how services.keyd runs, as providers.services units
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
  cfg = config.services.keyd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.keyd = {
      description = "keyd, a key remapping daemon";

      # the device manager has settled in the head tier, so the input devices keyd grabs are
      # there. syslogd is in that tier too and needs no naming.
      requires = [ "basic" ];

      type.service = {
        # keyd reads /etc/keyd, but the unit names every file that tree was generated from, so
        # a changed keymap is a changed unit. The same list used to be appended to
        # finit.d/keyd.conf as `# force a reload on configuration change` - which reached
        # finit and nothing else, so on any other init a new keymap needed a reboot.
        command = pkgs.writeShellScript "keyd" ''
          # reload triggers:
          ${lib.concatMapAttrsStringSep "\n" (_: v: "# ${v.source}") cfg.configTree}
          exec ${cfg.package}/bin/keyd
        '';

        # keyd is asked to re-read its own configuration, so a changed keymap no longer drops
        # the grabs on every keyboard
        reload = "${cfg.package}/bin/keyd reload";
      };

      environment = lib.optionalAttrs cfg.debug { KEYD_DEBUG = "2"; };
    };
  };
}
