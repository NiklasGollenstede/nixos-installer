{ description = (
    "Fully automated NixOS CLI installer"
); inputs = {

    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-26.05"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    systems.url = "github:nix-systems/default-linux";
    config.url = "path:./example/defaultConfig";

}; outputs = inputs: let patches = {

    nixpkgs = [
        #(throw "Should not be evaluated when using installer as input")
        ./patches/nixpkgs/pkgs-overridable.patch
    ];

}; in inputs.functions.lib.patchFlakeInputsAndImportRepo inputs patches ./. (inputs: repo': let
    repo = repo'.override { applyToPackages = pkgs: packages: builtins.removeAttrs packages [ "libblockdev" ]; };
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:

    ## Exports (things to reuse in other flakes):
    repo # lib.* nixosModules.* overlays.* packages.*

    ## Examples:
    # The example host definitions from ./hosts/, plus their installers (apps):
    (lib.self.mkSystemsFlake { inherit inputs; hosts.dir = "${inputs.self}/example/hosts"; asDefaultPackage = true; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems/default
    # The same cross-compiled from aarch64 (just to show how that works):
    (lib.self.mkSystemsFlake { inherit inputs; hosts.dir = "${inputs.self}/example/hosts"; buildPlatform = "aarch64-linux"; renameOutputs = name: "arm:${name}"; }) # nixosConfigurations.arm:* apps.*-linux.arm:* devShells.*-linux.arm:* packages.*-linux.arm:all-systems

]); }
