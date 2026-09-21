{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "limine-install";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Installs the limine bootloader for the system generations nix knows about";
    mainProgram = "limine-install";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
