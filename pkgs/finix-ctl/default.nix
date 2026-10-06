{
  lib,
  rustPlatform,
}:
# The `initctl` front-end. See src/main.rs for what it replaces.
#
# Dynamically linked, which is the deliberate difference from finix-init, finix-wait and
# finix-rc. Those are static because they run before the system is dependable - as pid 1, as its
# only child, or inside early units - and a closure is a liability there.
#
# This is none of those things: it is a command a person types on a machine which is already up.
# What it does need is `getpwuid` to mean what `id -un` meant, and that is an NSS lookup. A static
# musl build resolves it by reading /etc/passwd and nothing else, so on a machine whose users come
# from anywhere but that file it would quietly answer a different question than the shell did -
# and the answer decides which tree an unqualified unit name belongs to.
rustPlatform.buildRustPackage {
  pname = "finix-ctl";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # `resolve` is the only real logic here and it is a pure function of the index, so it is tested
  # here rather than in a VM. The VM tests in tests/providers assert the half this cannot: that
  # the command it decides to reach for is the one the backend actually supplied.
  doCheck = true;

  meta = {
    description = "inspect and control units across the system and user trees";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "initctl";
  };
}
