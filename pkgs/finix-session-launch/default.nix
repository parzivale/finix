{
  lib,
  pkgsStatic,
}:
# What a login session runs instead of its payload. See src/main.rs for what it does in which
# order, and for why the order is the design.
#
# `pkgsStatic`, as finix-wait and finix-init are: this is the first thing a session runs and the
# last thing it runs, so it is on the path of every login on the machine, and a static binary
# has no interpreter that has to be at exactly its store path for the session to start at all.
#
# The configuration it reads is /etc/finix/session-launch, written by
# `providers.services.user.sessionLauncher` - so this derivation is the same on every machine
# and the per-system part is a directory of files in /etc.
pkgsStatic.rustPlatform.buildRustPackage {
  pname = "finix-session-launch";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # no dependencies to resolve, so the lock has one entry and nothing to vendor.
  doCheck = false;

  stripAllList = [ "bin" ];

  meta = {
    description = "start a session's payload and the service tree beside it";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "finix-session-launch";
  };
}
