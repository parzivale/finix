# the directories a machine's users need, as providers.services rules
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
    # `mkOrder 400` rather than plain `mkBefore`: /home and the home directories under it have
    # to be made before anything else, and the base layout in system/activation is `mkBefore`
    # too - between two definitions of equal order the merge order decides, which is exactly
    # what stopped being stable when each module took its rules into a file of its own.
    providers.services.tmpfiles.rules = lib.mkOrder 400 (
      [
        {
          type = "directory";
          path = "/home";
        }
      ]
      ++
        lib.mapAttrsToList
          (username: opts: {
            path = opts.home;
            type.directory = {
              mode = "0700";
              user = opts.name;
              inherit (opts) group;
            };
          })
          (
            lib.filterAttrs (
              _: opts: opts.enable && opts.createHome && opts.home != "/var/empty"
            ) config.users.users
          )
    );
  };
}
