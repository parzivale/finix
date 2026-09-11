{
  description = "A collection of overlays, modules, libs, and templates for working with finix";

  outputs =
    { self }:
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

      formatter =
        let
          sources = import ./lon.nix;
          lib = import (sources.nixpkgs + "/lib");

          pkgsFor = system: import sources.nixpkgs { inherit system; };
        in
        lib.genAttrs' [ "aarch64-linux" "x86_64-linux" ] (
          system: lib.nameValuePair system (pkgsFor system).nixfmt-tree
        );

      # one runnable graphical VM per services backend, so that
      #
      #   nix run .#vm-dinit
      #
      # boots a machine with dinit as PID 1. Each carries meta.mainProgram, which is what lets
      # `nix run` pick the start script out of the derivation without an apps entry.
      packages =
        let
          sources = import ./lon.nix;
          lib = import (sources.nixpkgs + "/lib");

          pkgsFor = system: import sources.nixpkgs { inherit system; };
        in
        lib.genAttrs' [ "aarch64-linux" "x86_64-linux" ] (
          system:
          lib.nameValuePair system (
            lib.mapAttrs' (backend: vm: lib.nameValuePair "vm-${backend}" vm) (
              import ./vms { pkgs = pkgsFor system; }
            )
          )
        );
    };
}
