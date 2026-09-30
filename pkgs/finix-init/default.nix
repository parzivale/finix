{
  lib,
  pkgsStatic,
}:
# The preamble every boot path runs before its service manager. See src/main.rs for what it does
# and why it is one binary rather than a wrapper per backend.
#
# `pkgsStatic` is named here rather than left to the caller, because whether this is static is a
# property of the program and not of who is asking for it.
#
# Static, because of where it runs. On the no-initrd path the kernel has mounted the store device
# and exec'd this, and nothing has arranged anything else: /etc does not exist, and it is this
# binary that is about to cause it to. Linking dynamically would also make the store's layout part
# of the boot contract - the interpreter named in the ELF header has to be at exactly that path
# before a single instruction runs - and it would give this a closure, which matters the moment
# anything wants to put it in an image.
#
# musl rather than a static glibc: nixpkgs ships no static glibc, and asking rustc for
# `crt-static` against the dynamic one fails at the link with `cannot find -lutil`, which reads
# like a missing dependency rather than a libc that cannot do this.
pkgsStatic.rustPlatform.buildRustPackage {
  pname = "finix-init";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  # there is no way to be PID 1 in a build sandbox, so what tests exist are the VM tests
  doCheck = false;

  # `--strip-all`, not the `--strip-debug` the fixup phase does by default. Most of what is left
  # in a release build is the symbol table, and nothing here reads it: a backtrace would need a
  # panic handler that unwinds, and this aborts. 634k to 463k, which is 27% - more than any
  # opt-level is worth here. `opt-level = "z"` was measured and made it *bigger* (652k): it turns
  # off loop vectorisation, and with LTO on that costs more elsewhere than it saves.
  stripAllList = [ "bin" ];

  meta = {
    description = "finix PID 1 preamble: prepare /, activate the configuration, exec the service manager";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "finix-init";
  };
}
