# how services.dhcpcd runs, as providers.services units
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
  cfg = config.services.dhcpcd;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.dhcpcd = {
      description = "dhcp client";

      type.service = {
        # PATH set in the command rather than asked for as a unit property: dinit has no
        # per-unit PATH, and dhcpcd needs resolvconf on it to write /etc/resolv.conf.
        command = pkgs.writeShellScript "dhcpcd" ''
          ${lib.optionalString config.programs.resolvconf.enable "export PATH=${config.programs.resolvconf.package}/bin:$PATH"}
          exec ${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs}
        '';

        readiness = "fork";
      };

      # `basic` puts it in the multi-user tier. Not the basic tier: nothing before multi-user
      # needs the network, and gating `basic` on a DHCP lease would stall the whole trunk on a
      # machine with no link. syslogd is in the head tier, so this is already after it.
      # `basic` puts it in the multi-user tier, which is after the head tier the device
      # manager settles in - so neither that nor syslogd is named here any more.
      requires = [ "basic" ];
    };

  };
}
