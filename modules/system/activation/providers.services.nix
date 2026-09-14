# the base filesystem layout, as providers.services rules
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
{
  config = {
    providers.services.tmpfiles.rules = lib.mkBefore (
      map
        (path: {
          type = "directory";
          inherit path;
        })
        [
          "/etc"
          "/run"
          "/var"
          "/var/cache"
          "/var/db"
          "/var/empty"
          "/var/lib"
          "/var/log"
          "/var/spool"
        ]
      ++ [
        # world-writable and sticky, which is the whole point of /tmp - left at the default
        # 0755 root:root nothing unprivileged on the machine can write a temporary file, and
        # what that looks like is a program failing on a path it had every reason to expect
        {
          path = "/tmp";
          type.directory.mode = "1777";
        }

        {
          path = "/var/run";
          type.symlink.argument = "/run";
        }
      ]
    );
  };
}
