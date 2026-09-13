# what xwayland-satellite puts in place, as providers.services rules and units
#
# Separated from the module's own options and configuration so that what this module asks of
# the contract is in one place, the same way a module implementing a `providers.*` contract
# keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.xwayland-satellite;
in
{
  config = lib.mkIf cfg.enable {
    providers.services.tmpfiles.rules =
      lib.concatMap
        (path: [
          {
            type = "remove";
            inherit path;
            recursive = true;
          }
          {
            type = "directory";
            inherit path;
            mode = "1777";
          }
        ])
        [
          "/tmp/.X11-unix"
          "/tmp/.ICE-unix"
          "/tmp/.XIM-unix"
          "/tmp/.font-unix"
        ]
      ++ [
        # a lock naming a server which is no longer running
        {
          type = "remove";
          path = "/tmp/.X[0-9]*-lock";
        }
      ];
  };
}
