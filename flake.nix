{
  description = "A collection of overlays, modules, libs, and templates for working with finix";

  outputs =
    { self }:
    let
      sources = import ./lon.nix;
      lib = import (sources.nixpkgs + "/lib");

      pkgsFor = system: import sources.nixpkgs { inherit system; };

      forAllSystems =
        f:
        lib.genAttrs' [ "aarch64-linux" "x86_64-linux" ] (
          system: lib.nameValuePair system (f (pkgsFor system))
        );
    in
    {
      nixosModules = import ./modules;

      lib.finixSystem =
        {
          lib ? null,
          specialArgs ? { },
          modules ? [ ],
          ...
        }:
        let
          config = lib.evalModules {
            class = "nixos";
            specialArgs = lib.recursiveUpdate { modules = self.nixosModules; } specialArgs;
            modules = [ self.nixosModules.default ] ++ modules;
          };
        in
        config
        // {
          inherit (config._module.args) pkgs;
          inherit lib;
        };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      # opt-in: `nix develop .#rust`, or `nix-shell -A devShells.<system>.rust`
      devShells = forAllSystems (pkgs: {
        rust = pkgs.mkShell {
          name = "finix-rust";

          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.clippy
            pkgs.rustfmt
            pkgs.rust-analyzer
          ];

          env.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
        };
      });
    };
}
