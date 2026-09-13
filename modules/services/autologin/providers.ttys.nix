# what services.autologin puts on a terminal, as a providers.ttys device
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
  cfg = config.services.autologin;
in
{
  config = lib.mkIf cfg.enable {
    # autologin is hardcoded to run on tty1, so it claims it. That claim is the whole of what
    # used to be `finit.ttys.tty1.enable = lib.mkForce false` plus a service of its own - and
    # the force only ever reached finit, so on any other init a getty held tty1 at the same
    # time and the two fought over the keyboard.
    providers.ttys.devices.tty1 = {
      description = "autologin";

      # the redirect is autologin's own business: unlike a getty it does not take a device, so
      # the terminal has to be its standard streams before it is exec'd. Which is what finit
      # was arranging on its behalf when this was a `tty` stanza with no command.
      command = pkgs.writeShellScript "autologin-tty1" ''
        exec </dev/tty1 >/dev/tty1 2>&1
        exec ${lib.getExe pkgs.autologin} ${cfg.user} ${cfg.command}
      '';

      # `multi-user`, like any other login prompt: a session before the system is up is a
      # session into a half-built machine.
      #
      # That one edge is the whole of it now. This used to name five things one at a time -
      # syslogd, the device manager's settle, elogind, sessiond, seatd's socket - and every one
      # of them is in an earlier tier, including the socket gates, so the trunk says it all.
      requires = [ "multi-user" ];
    };
  };
}
