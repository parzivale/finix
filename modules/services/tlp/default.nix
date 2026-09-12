{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.tlp;
  tlpExe = lib.getExe cfg.package;

  format = pkgs.formats.keyValue {
    mkKeyValue = lib.generators.mkKeyValueDefault { } "=";
    listToValue = l: "\"${toString l}\"";
  };
in
{
  options.services.tlp = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [tlp](${pkgs.tlp.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.tlp;
      defaultText = lib.literalExpression "pkgs.tlp";
      description = ''
        The package to use for `tlp`.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `tlp` configuration. See [upstream documentation](https://linrunner.de/tlp/settings)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."tlp.conf".source = format.generate "tlp.conf" cfg.settings;

    environment.systemPackages = [
      cfg.package
    ];

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = "/var/lib/tlp";
      }
    ];

    providers.resumeAndSuspend.hooks = {
      "tlp@suspend" = {
        event = "suspend";
        action = "${tlpExe} suspend";
      };

      "tlp@resume" = {
        event = "resume";
        action = "${tlpExe} resume";
      };
    };

    services.udev.packages = [ cfg.package ];

    # TODO: revisit rules... compare with udev
    services.mdevd.hotplugRules = ''
      # handle change of power source ac/bat
      -SUBSYSTEM=power_supply;.* root:root 0600 &${tlpExe} auto

      # handle added usb devices
      # -SUBSYSTEM=usb;DEVTYPE=usb_device;.* root:root 0600 +${cfg.package}/lib/udev/tlp-usb-udev usb /sys/$DEVPATH

      # handle added usb disk devices
      # -SUBSYSTEM=block;DEVTYPE=disk;.* root:root 0600 +${cfg.package}/lib/udev/tlp-usb-udev disk /sys/$DEVPATH
    '';

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
        # applied again whenever this changes: ${config.environment.etc."tlp.conf".source}
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
  };
}
