# finix test suite
#
# auto-discovers and exposes all tests in this directory and subdirectories.
# similar to nixos/tests/all-tests.nix in nixpkgs.
#
# usage:
#   nix-build tests                   # build all tests
#   nix-build tests -A boot           # build specific test
#   nix-build tests -A finit.tmpfiles # build test from subdirectory
#
# interactive mode:
#   nix-build tests -A boot.driverInteractive
#   ./result/bin/finix-test-driver
{
  pkgs ?
    let
      sources = import ../lon.nix;
    in
    import sources.nixpkgs { },

  # callTest wraps mkTest - allows caller to customize test invocation
  # default is null, meaning use the standard testLib.mkTest
  callTest ? null,
}:
let
  inherit (pkgs) lib;

  testLib = import ./lib { inherit lib pkgs; };
  runTest = if callTest != null then callTest else (file: testLib.mkTest (import file));

  # files/directories to exclude from auto-discovery
  excludes = [
    "default.nix"
    "lib"
  ];

  dirContents = builtins.readDir ./.;

  # discover .nix files in the top-level directory
  topLevelTests =
    lib.mapAttrs'
      (filename: _: {
        name = lib.removeSuffix ".nix" filename;
        value = runTest (./. + "/${filename}");
      })
      (
        lib.filterAttrs (
          name: type: type == "regular" && lib.hasSuffix ".nix" name && !(builtins.elem name excludes)
        ) dirContents
      );

  # discover subdirectories (excluding lib and other excludes)
  subDirs = lib.filterAttrs (
    name: type: type == "directory" && !(builtins.elem name excludes)
  ) dirContents;

  # for each subdirectory, create a nested attrset of tests
  # e.g., finit/tmpfiles.nix -> finit.tmpfiles
  # use recurseIntoAttrs so nix-build recurses into subdirectories
  subDirTests = lib.mapAttrs (
    dirName: _:
    let
      dir = ./. + "/${dirName}";

      subDirContents = builtins.readDir dir;
      nixFiles = lib.filterAttrs (
        name: type: type == "regular" && lib.hasSuffix ".nix" name
      ) subDirContents;
    in
    # a directory with a default.nix describes its own tests, rather than being one file one
    # test. That is for a suite where the same test runs against several implementations: the
    # file is a function of which one, so there is nothing for auto-discovery to import.
    if subDirContents ? "default.nix" then
      lib.recurseIntoAttrs (
        import dir {
          inherit lib pkgs runTest;
          mkTest = testLib.mkTest;
        }
      )
    else
      lib.recurseIntoAttrs (
        lib.mapAttrs' (filename: _: {
          name = lib.removeSuffix ".nix" filename;
          value = runTest (dir + "/${filename}");
        }) nixFiles
      )
  ) subDirs;
in
topLevelTests // subDirTests
