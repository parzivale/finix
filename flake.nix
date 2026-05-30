{
  description = "A collection of overlays, modules, libs, and templates for working with finix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
  };

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
    };
}
