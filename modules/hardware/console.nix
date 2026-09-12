{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.hardware.console;

  mkBinaryKeyMap =
    km:
    pkgs.runCommand "bkeymap"
      {
        nativeBuildInputs = [ pkgs.buildPackages.kbd ];
        preferLocalBuild = true;
      }
      ''
        loadkeys --bkeymap "${km}" >$out
      '';

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

  loadkmapTask = {
    description = "load console keymap";
    conditions = "dev/console";
    command = "${pkgs.busybox}/bin/loadkmap < ${cfg.binaryKeyMap}";
  };
in
{
  options = {
    hardware.console = {
      enable = lib.mkOption {
        description = "Whether to configure the console at boot.";
        type = lib.types.bool;
        default = true;
      };

      setvesablank = lib.mkOption {
        description = "Turn VESA screen blanking on or off.";
        type = lib.types.bool;
        default = true;
      };

      keyMap = lib.mkOption {
        type = with lib.types; either str path;
        default = "us";
        description = ''
          The keyboard mapping table for the virtual consoles.
          This option may have no effect if hardware.console.binaryKeyMap is set.
        '';
      };

      binaryKeyMap = lib.mkOption {
        description = ''
          Binary keymap file.
          If unset then this is generated from the hardware.console.keyMap option.
        '';
        type = lib.types.path;
        default = mkBinaryKeyMap cfg.keyMap;
        defaultText = "Binary form of hardware.console.keyMap.";
      };

      font = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "Lat2-Terminus16";
        description = ''
          The font to use for the virtual consoles.
          Set to null to use the kernel default.
          Must be available in kbd or one of the packages in
          hardware.console.packages.
        '';
      };

      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = ''
          Extra packages providing console fonts and keymaps
          (beyond the default kbd package).
        '';
      };

      earlySetup = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to set the font in the initrd. Useful if you want the
          right font before the system fully boots.
        '';
      };

      colors = lib.mkOption {
        type = with lib.types; listOf str;
        default = [ ];
        description = ''
          A list of 16 terminal color codes, in the format RRGGBB,
          to override the default terminal colors. For example,
          a Nord-like palette. Leave empty to use defaults.
        '';
        example = [
          "2E3440"
          "BF616A"
          "A3BE8C"
          "EBCB8B"
          "81A1C1"
          "B48EAD"
          "88C0D0"
          "E5E9F0"
          "4C566A"
          "BF616A"
          "A3BE8C"
          "EBCB8B"
          "81A1C1"
          "B48EAD"
          "8FBCBB"
          "ECEFF4"
        ];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.kbd ] ++ cfg.packages;

    # Include binary keymap in the initramfs, and optionally the console font.
    boot.initrd.contents = [
      { source = cfg.binaryKeyMap; }
    ]
    ++ lib.optional (cfg.earlySetup && cfg.font != null) {
      source = "${fontEnv}/share/consolefonts/${cfg.font}";
      target = "/console-font";
    };

    # Console node ownership and mode; mdevd has no defaults for this.
    services.mdevd.coldplugRules = "-console 0:${toString config.ids.gids.tty} 600";

    # the initrd stays finit's, and keeps the stanza; stage 2 is the contract's, so the same
    # command becomes a unit there. Written as a stanza it loaded the keymap on finit and left
    # every other init with a us layout whatever was configured.
    boot.initrd.finit.tasks.loadkmap = loadkmapTask;

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

    boot.initrd.fileSystemImportCommands = lib.mkIf (cfg.earlySetup && cfg.font != null) ''
      ${pkgs.kbd}/bin/setfont /console-font -C /dev/console 2>/dev/null || true
    '';
  };

  imports = [
    (lib.mkRenamedOptionModule [ "console" ] [ "hardware" "console" ])
  ];
}
