# module tests with a machine under them, once per implementation
#
# tests/modules evaluates every module against every init and asks whether its units are
# coherent: no dangling edge, no readiness the backend cannot observe, no cycle, no stanza left
# behind. That is cheap enough to run over all 106 modules and catches the whole class of
# mistakes the port could make. What it cannot do is boot, so it never answers the question the
# module exists for - does the daemon work?
#
# These do. Each file here enables one real module and asserts something only a running system
# can show, and each is instantiated once per implementation - `nix-build tests -A
# modules-vm.openssh.s6-rc`, or the whole row with `-A modules-vm.openssh`.
#
# There is deliberately no attempt to cover every module this way. A VM per module per init is
# 424 machines, most of which would assert nothing more than "it booted" - which the trunk
# already guarantees, since every unit a module adds is something a trunk level waits for. The
# modules worth a machine are the ones whose behaviour is not implied by their unit graph: a
# daemon which has to serve something, a protocol which has to be spoken, an ordering whose
# failure is silent.
{
  lib,
  pkgs,
  mkTest,
  ...
}:
let
  testLib = import ../lib { inherit lib pkgs; };

  backends = [
    "finit"
    "dinit"
    "runit"
    "s6-rc"
  ];

  modules = {
    openssh = ./openssh.nix;
  };

  # one row: the same test file, instantiated once per implementation
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
in
lib.mapAttrs (_: row) modules
