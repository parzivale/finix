{
  lib,
  pkgsStatic,
}:
# The supervision the thin backends are built out of, as one binary. See src/main.rs for what it
# replaces and why it stopped being shell.
#
# `pkgsStatic` for finix-init's reason, and here it is the sharp version of it rather than the
# mild one: this *is* rc.init, the single child pid 1 execs, and on the no-initrd boot path it
# runs before anything has had a chance to go wrong. A static binary has no closure - no
# interpreter which has to be at exactly its store path before the first instruction. The shell
# version needed bash, coreutils, util-linux and busybox all resolvable at that moment; this
# needs nothing but itself.
#
# It is also what makes the nxinit `/dev/fd` workaround unnecessary for rc.init specifically:
# that backend execs its child with execveat(2) and AT_EMPTY_PATH, which the kernel cannot use to
# resolve a `#!` line, so a shell script had to be reachable through a /dev/fd that udev had not
# created yet. An ELF has no shebang to resolve.
pkgsStatic.rustPlatform.buildRustPackage {
  pname = "finix-rc";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # nothing to run here that would not want a machine to run it on: every meaningful assertion
  # about this binary is a VM test in tests/providers, where there is an init to be pid 1.
  doCheck = false;

  stripAllList = [ "bin" ];

  meta = {
    description = "jobs, the trunk, shutdown and switch for an init which has none of them";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "finix-rc";
  };
}
