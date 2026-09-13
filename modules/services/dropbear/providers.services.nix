# how services.dropbear runs, as providers.services units
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
  cfg = config.services.dropbear;
  stateDir = "/var/lib/dropbear";

in
{
  config = lib.mkIf cfg.enable {
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
