{
  lib,
  pkgsStatic,
}:
# The `waitFor` readiness kinds, as one binary with a subcommand each. See src/main.rs for why
# this is a program rather than the generated shell it replaces.
#
# `pkgsStatic` for the same reason as finix-init, though less sharply: this runs as part of early
# units on every backend, and a static binary has no closure - no interpreter that has to be at
# exactly its store path before the first instruction, and nothing to pull into an image that
# wants to carry the service graph. It also drops socat and inotify-tools out of every system
# that uses `waitFor`, which is every system.
pkgsStatic.rustPlatform.buildRustPackage {
  pname = "finix-wait";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # no dependencies to resolve, so the lock has one entry and nothing to vendor.
  doCheck = false;

  stripAllList = [ "bin" ];

  meta = {
    description = "block until a path, socket or pidfile says its unit is live";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "finix-wait";
  };
}
