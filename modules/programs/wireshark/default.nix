{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.wireshark;
in
{
  options.programs.wireshark = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [wireshark](${pkgs.wireshark.meta.homepage}) and create a
        `wireshark` group. What members of that group may capture is decided by
        {option}`programs.wireshark.dumpcap.enable` and
        {option}`programs.wireshark.usbmon.enable`; by default they may capture
        network traffic but not USB traffic.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.wireshark-cli;
      defaultText = lib.literalExpression "pkgs.wireshark-cli";
      description = ''
        The package to use for `wireshark`. `pkgs.wireshark` for the Qt
        interface.
      '';
    };

    dumpcap.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether members of the `wireshark` group may capture network traffic.
        Wraps `dumpcap` with the capabilities it needs, owned by that group.
      '';
    };

    usbmon.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether members of the `wireshark` group may capture USB traffic. Adds
        udev rules giving that group read access to the `usbmon` subsystem.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    users.groups.wireshark = { };

    # dumpcap is the part that opens the interface, so it is the part that
    # carries the capabilities: cap_net_raw to open a capture socket and
    # cap_net_admin to put the interface into promiscuous mode. `+eip` rather
    # than setuid root, so the process holds those two and nothing else.
    security.wrappers.dumpcap = lib.mkIf cfg.dumpcap.enable {
      source = "${cfg.package}/bin/dumpcap";
      capabilities = "cap_net_raw,cap_net_admin+eip";
      owner = "root";
      group = "wireshark";
      permissions = "u+rx,g+x";
    };

    # Only the udev backend: a machine on mdevd or keventd wants the equivalent
    # rule in that backend's own vocabulary, which is not something this module
    # can write for it.
    services.udev.packages = lib.mkIf cfg.usbmon.enable [
      (pkgs.writeTextDir "etc/udev/rules.d/85-wireshark-usbmon.rules" ''
        SUBSYSTEM=="usbmon", MODE="0640", GROUP="wireshark"
      '')
    ];
  };
}
