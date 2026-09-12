{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.blocky;

  format = pkgs.formats.yaml { };
  configFile = format.generate "config.yaml" cfg.settings;
in
{
  options.services.blocky = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [blocky](${pkgs.blocky.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.blocky;
      defaultText = lib.literalExpression "pkgs.blocky";
      description = ''
        The package to use for `blocky`.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable debug logging.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "blocky";
      description = ''
        User account under which `blocky` runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the `blocky` service starts.
        :::
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "blocky";
      description = ''
        Group account under which `blocky` runs.

        ::: {.note}
        If left as the default value this group will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the group exists before the `blocky` service starts.
        :::
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `blocky` configuration. See [upstream documentation](https://0xerr0r.github.io/blocky/configuration)
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.blocky.settings = {
      log = {
        level = lib.mkIf cfg.debug "debug";
        timestamp = false;
      };

      queryLog.type = lib.mkDefault "none";
    };

    providers.services.units.blocky = {
      inherit (cfg) user group;

      description = "a dns proxy and ad-blocker for the local network";

      requires = [
        "basic"
        "network-online"
      ];

      # `caps = [ "^cap_net_bind_service" ]` was finit's own capability handling, which the
      # contract does not model - and this needs it, since it binds port 53 as a non-root user.
      # `setpriv` carries the capability into the process instead, which works on every
      # implementation rather than on the one with a `caps` stanza.
      type.service.command = pkgs.writeShellScript "blocky" ''
        exec ${lib.getExe' pkgs.util-linux "setpriv"} \
          --ambient-caps +cap_net_bind_service \
          -- ${lib.getExe cfg.package} --config ${configFile} "$@"
      '';
    };

    users.users = lib.mkIf (cfg.user == "blocky") {
      blocky = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

    users.groups = lib.mkIf (cfg.group == "blocky") {
      blocky = { };
    };
  };
}
