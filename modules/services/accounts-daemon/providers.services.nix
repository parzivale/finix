# how services.accounts-daemon runs, as providers.services units
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
  cfg = config.services.accounts-daemon;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.accounts-daemon = {
      description = "accounts service";

      # nothing about the bus: it and its socket gate are in the head tier, so anything here
      # is after them
      requires = [ "basic" ];

      type.service.command =
        "${cfg.package}/libexec/accounts-daemon" + lib.optionalString cfg.debug " --debug";

      environment = {
        GVFS_DISABLE_FUSE = 1;
        GIO_USE_VFS = "local";
        GVFS_REMOTE_VOLUME_MONITOR_IGNORE = 1;

        # accounts daemon looks for dbus interfaces in $XDG_DATA_DIRS/accountsservice
        XDG_DATA_DIRS = "/run/current-system/sw/share"; # "${config.system.path}/share";
      }
      //
        lib.optionalAttrs true # config.users.mutableUsers
          {
            NIXOS_USERS_PURE = "true";
          };
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/lib/AccountsService";
        type.directory.mode = "0775";
      }
    ];
  };
}
