{ description = (
    "Work In Progress: a collection of Nix things that are used in more than one project, but aren't refined enough to be standalone libraries/modules/... (yet)."
    # This flake file defines the inputs (other than except some files/archives fetched by hardcoded hash) and exports all results produced by this repository.
    # It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-22.05"; };
    nixos-hardware = { url = "github:NixOS/nixos-hardware/master"; };
    config = { type = "github"; owner = "NiklasGollenstede"; repo = "nix-wiplib"; dir = "example/defaultConfig"; rev = "5e9cc7ce3440be9ce6aeeaedcc70db9c80489c5f"; }; # Use some previous commit's »./example/defaultConfig/flake.nix« as the default config for this flake.

}; outputs = inputs: let patches = {

    nixpkgs = [ # Can define a list of patches for each input here:
        # { url = "https://github.com/NixOS/nixpkgs/pull/###.diff"; sha256 = inputs.nixpkgs.lib.fakeSha256; } # Path from URL.
        # ./patches/nixpkgs-fix-systemd-boot-install.patch # Local path file. (use long native / direct path to ensure it only changes if the content does)
        # ./patches/nixpkgs-test.patch # After »nix build«, check »result/inputs/nixpkgs/patched!« to see that these patches were applied.
    ];

}; in (import "${./.}/lib/flakes.nix" "${./.}/lib" inputs).patchFlakeInputsAndImportRepo inputs patches ./. (inputs@{ self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo # lib.* nixosModules.* overlays.*
    (lib.wip.mkSystemsFlake { inherit inputs; moduleInputs = builtins.removeAttrs inputs [ "nixpkgs" "nixos-hardware" ]; }) # nixosConfigurations.* apps.*-linux.* devShells.*-linux.* packages.*-linux.all-systems
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: { # packages.*-linux.* defaultPackage.*-linux
        packages = builtins.removeAttrs (lib.wip.getModifiedPackages (lib.wip.importPkgs inputs { system = localSystem; }) overlays) [ "libblockdev" ];
        defaultPackage = self.packages.${localSystem}.all-systems;
    }))
    { patches = (lib.wip.importWrapped inputs "${self}/patches").result; } # patches.*
]); }
