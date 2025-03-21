{ description = (
    "Fully automated NixOS CLI installer"
); inputs = {

    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-24.11"; };
    functions = { url = "github:NiklasGollenstede/nix-functions"; inputs.nixpkgs.follows = "nixpkgs"; };
    config.url = "github:NiklasGollenstede/nixos-installer?dir=example/defaultConfig"; # "path:./example/defaultConfig"; # (The latter only works on each host after using this flake directly (not as dependency or another flake). The former effectively points to the last commit, i.e. it takes two commits to apply changes to the default config.)

}; outputs = inputs@{ self, ... }: inputs.functions.lib.importRepo inputs ./. (repo': let
    repo = repo'.override { applyToPackages = pkgs: packages: builtins.removeAttrs packages [ "libblockdev" ]; };
    lib = repo.lib.__internal__;
in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:

    ## Exports (things to reuse in other flakes):
    repo # lib.* nixosModules.* overlays.* packages.*

    ## Examples:
    # The example host definitions from ./hosts/, plus their installers (apps):
    (lib.self.mkSystemsFlake { inherit inputs; hosts.dir = "${self}/example/hosts"; asDefaultPackage = true; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems/default
    # The same cross-compiled from aarch64 (just to show how that works):
    (lib.self.mkSystemsFlake { inherit inputs; hosts.dir = "${self}/example/hosts"; buildPlatform = "aarch64-linux"; renameOutputs = name: "arm:${name}"; }) # nixosConfigurations.arm:* apps.*-linux.arm:* devShells.*-linux.arm:* packages.*-linux.arm:all-systems

]); }
