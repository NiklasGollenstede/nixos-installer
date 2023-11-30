{ description = (
    "Fully automated NixOS CLI installer"
); inputs = {

    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-23.11"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    config.url = "path:./example/defaultConfig";

}; outputs = inputs@{ self, ... }: inputs.functions.lib.importRepo inputs ./. (repo@{ overlays, ... }: let
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:

    ## Exports (things to reuse in other flakes):
    (repo // { packages = lib.fun.packagesFromOverlay { inherit inputs; exclude = [ "libblockdev" ]; }; }) # lib.* nixosModules.* overlays.* packages.*

    ## Examples:
    # The example host definitions from ./hosts/, plus their installers (apps):
    (lib.self.mkSystemsFlake { inherit inputs; asDefaultPackage = true; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems/default
    # The same cross-compiled from aarch64 (just to show how that works):
    (lib.self.mkSystemsFlake { inherit inputs; buildPlatform = "aarch64-linux"; renameOutputs = name: "arm:${name}"; }) # nixosConfigurations.arm:* apps.*-linux.arm:* devShells.*-linux.arm:* packages.*-linux.arm:all-systems

]); }
