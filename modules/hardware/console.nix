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
          This option may have no effect if
          hardware.console.binaryKeyMap is set.
        '';
      };

      binaryKeyMap = lib.mkOption {
        description = ''
          Binary keymap file.
          If unset then this is generated from
          the hardware.console.keyMap option.
        '';
        type = lib.types.path;
        default = mkBinaryKeyMap cfg.keyMap;
        defaultText = "Binary form of hardware.console.keyMap.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.kbd ];

    # Include binary keymap in the initramfs.
    boot.initrd.contents = [ { source = cfg.binaryKeyMap; } ];

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
  };

  imports = [
    (lib.mkRenamedOptionModule [ "console" ] [ "hardware" "console" ])
  ];
}
