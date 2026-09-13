# how the console is set up, as providers.services units
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.hardware.console;

  # the font and colour commands, restated here beside the unit which runs them
  fontEnv = pkgs.buildEnv {
    name = "console-fonts";
    paths = [ pkgs.kbd ] ++ cfg.packages;
    pathsToLink = [
      "/share/consolefonts"
      "/share/kbd/consolefonts"
    ];
  };

  setfontCmd =
    if cfg.font == null then
      null
    else
      let
        fontArg = lib.escapeShellArg cfg.font;
        mapArg = lib.optionalString (
          cfg.keyMap != null
        ) " -m ${fontEnv}/share/consolefonts/${lib.escapeShellArg cfg.keyMap}.acm 2>/dev/null || true";
      in
      "${pkgs.kbd}/bin/setfont ${fontArg} -C /dev/console || ${pkgs.kbd}/bin/setfont ${fontEnv}/share/consolefonts/${fontArg} -C /dev/console${mapArg}";

  colorsScript = lib.optionalString (cfg.colors != [ ]) (
    let
      inherit (lib) imap0 concatStringsSep;
      esc = "\033]P";
      entries = imap0 (i: c: "${esc}${lib.toHexString i}${c}") cfg.colors;
    in
    ''printf "${concatStringsSep "" entries}" > /dev/console''
  );
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.loadkmap = {
      description = "load console keymap";

      # `conditions = "dev/console"` was finit waiting for the device node. The device manager
      # is what puts it there, and it is in the head tier, so this sits in the tier after it.
      requires = [ "sysinit" ];

      # reported rather than fatal, like the finit task this was: nothing waited on a task, but
      # every level above `sysinit` waits on a unit, and a console which will not take a keymap
      # is not a reason to stop booting - it is a reason to say so and carry on with us.
      type.oneshot.command = pkgs.writeShellScript "loadkmap" ''
        ${pkgs.busybox}/bin/loadkmap < ${cfg.binaryKeyMap} ||
          echo "loadkmap: could not load the console keymap; continuing" >&2
      '';
    };

    providers.services.units.setvesablank =
      let
        value = if cfg.setvesablank then "on" else "off";
      in
      {
        description = "turn vesa screen blanking ${value}";

        # the logger is in the head tier, which `sysinit` is already behind
        requires = [ "sysinit" ];

        # plenty of consoles have no VESA blanking to turn ${value}, and on those setvesablank
        # fails. That was a line in the log when this was a finit task; as a unit it would hold
        # every level above `sysinit`, which is a heavy price for a screensaver.
        type.oneshot.command = pkgs.writeShellScript "setvesablank" ''
          ${pkgs.kbd}/bin/setvesablank ${value} ||
            echo "setvesablank: this console does not support blanking; continuing" >&2
        '';
      };

    providers.services.units.console-setup = lib.mkIf (cfg.font != null || cfg.colors != [ ]) {
      description = "set console font and colors";

      # `runlevels = "S"` with a condition on syslogd is `sysinit` here: the logger is in the
      # head tier, which this is already behind
      requires = [ "sysinit" ];

      # a font this console will not take is not a reason to stop booting - and as a unit it
      # would be, since every level above `sysinit` waits for this one. Same bargain as
      # setvesablank and loadkmap beside it.
      type.oneshot.command = pkgs.writeShellScript "console-setup" ''
        ${lib.optionalString (cfg.font != null) setfontCmd}
        ${colorsScript}
        exit 0
      '';
    };
  };
}
