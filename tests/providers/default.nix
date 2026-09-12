# the providers.services suite: a core matrix, plus what only one implementation can say
#
# The core tests are written once and run against every backend. That is the point of them:
# `providers.ordering.runit` and `providers.ordering.finit` are the same assertions about the
# same configuration, so a difference in the result is a difference in the implementation and
# not in the test. Each is reachable on its own - `nix-build tests -A providers.ordering.dinit`
# - or a whole row at once, as `-A providers.ordering`.
#
# They may only assert what the contract promises. Console banners, the supervisor's own CLI and
# runit's latch files are all off limits, because each is one implementation's vocabulary; see
# core/lib.nix, which is where that restriction is written down and worked around.
#
# The per-backend tests beside them are the opposite: each says something only its own target
# can. finit's conditions and companion latches, dinit's milestones, s6's native notification
# protocol, runit holding synthesised edges while runsvdir starts everything at once. The matrix
# proves the contract; these prove the translation onto each target, and folding them in would
# lose that.
{
  lib,
  pkgs,
  runTest,
  mkTest,
}:
let
  testLib = import ../lib { inherit lib pkgs; };

  backends = [
    "finit"
    "dinit"
    "runit"
    "s6-rc"
  ];

  core = {
    ordering = ./core/ordering.nix;
    readiness = ./core/readiness.nix;
    switching = ./core/switching.nix;
    users = ./core/users.nix;
    shutdown = ./core/shutdown.nix;

    # ordering and shutdown again, with the timing made hostile. Kept separate from them so a
    # failure says which it is: the claim being broken, or only the easy version of it holding.
    stress = ./core/stress.nix;
  };

  # one row of the matrix: the same test file, instantiated once per implementation
  row =
    file:
    lib.recurseIntoAttrs (
      lib.genAttrs backends (
        backend:
        mkTest (
          import file {
            inherit
              pkgs
              lib
              testLib
              backend
              ;
          }
        )
      )
    );

  # everything else in this directory is one file, one test, discovered the way the rest of the
  # suite is. `core` is a directory of functions rather than tests, so it is not among them.
  perBackend =
    lib.mapAttrs'
      (filename: _: {
        name = lib.removeSuffix ".nix" filename;
        value = runTest (./. + "/${filename}");
      })
      (lib.filterAttrs (name: type: type == "regular" && name != "default.nix") (builtins.readDir ./.));
in
lib.mapAttrs (_: row) core // perBackend
