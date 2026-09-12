{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.dropbear;

  stateDir = "/var/lib/dropbear";

  keyOpts =
    { config, ... }:
    {
      options = {
        type = lib.mkOption {
          type = lib.types.enum [
            "rsa"
            "ecdsa"
            "ed25519"
          ];
          default = "ed25519";
          description = ''
            The type of key to generate.
          '';
        };

        path = lib.mkOption {
          type = lib.types.path;
          description = ''
            Write the secret key to this path.
          '';
        };

        bits = lib.mkOption {
          type = with lib.types; nullOr int;
          default = null;
          description = ''
            Set the key size in bits.

            ::: {.note}
            Should be multiple of `8`.
            :::
          '';
        };

        comment = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            Specify the key comment (email).
          '';
        };
      };

      config = {
        path = lib.mkDefault "${stateDir}/dropbear_${config.type}_host_key";
      };
    };
in
{
  options.services.dropbear = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [dropbear](${pkgs.dropbear.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dropbear;
      defaultText = lib.literalExpression "pkgs.dropbear";
      description = ''
        The package to use for `dropbear`.
      '';
    };

    hostKeys = lib.mkOption {
      type = with lib.types; listOf (submodule keyOpts);
      default = [
        {
          # default
        }
      ];
      defaultText = [
        {
          type = "ed25519";
          path = "${stateDir}/dropbear_ed25519_host_key";
        }
      ];
      description = ''
        `finix` will automatically generate SSH host keys using {manpage}`dropbearkey(1)` on startup.

        ::: {.note}
        Automatic generation of host keys can be disabled by setting a value of `lib.mkForce [ ]`.
        :::
      '';
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = ''
        Additional arguments to pass to `dropbear`. See {manpage}`dropbear(8)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.dropbear.extraArgs = lib.concatMap (key: [
      "-r"
      key.path
    ]) cfg.hostKeys;

    environment.systemPackages = [
      cfg.package
    ];

    providers.services.units.dropbear-keygen = {
      description = "generate ssh host keys";

      # before anything can serve with them, and before the tier which completes `basic`
      requires = [ "sysinit" ];

      type.oneshot.command =
        let
          script = lib.concatMapStringsSep "\n" (key: ''
            if ! [ -s "${key.path}" ]; then
              ${cfg.package}/bin/dropbearkey -t ${key.type} -f "${key.path}" ${
                lib.optionalString (key.bits != null) "-s ${toString key.bits}"
              } ${lib.optionalString (key.comment != null) "-C \"${key.comment}\""}
            fi
          '') config.services.dropbear.hostKeys;
        in
        pkgs.writeShellScript "ssh-keygen.sh" script;
    };

    providers.services.units.dropbear = {
      description = "dropbear ssh daemon";

      # `basic`, where the rest of the network daemons are. `net/lo/up` and
      # `service/syslogd/ready` are both behind it - loopback and the logger come up in the
      # tier which completes `basic` - so only the keys still need naming, and they are named
      # because a daemon serving before they exist offers a host identity it then changes.
      requires = [
        "basic"
        "dropbear-keygen"
      ];

      type.service.command = "${cfg.package}/bin/dropbear -F " + lib.escapeShellArgs cfg.extraArgs;

      # TODO: dropbear doesn't use PAM so we need to keep these variables in sync with security.pam.environment!
      # NOTE: dropbear will only respect PATH and LD_LIBRARY_PATH
      path = [
        (dirOf config.security.wrapperDir)
        "/run/current-system/sw"
      ];
    };

    providers.services.tmpfiles.rules = [
      {
        type = "directory";
        path = stateDir;
        mode = "0755";
      }
    ];
  };
}
