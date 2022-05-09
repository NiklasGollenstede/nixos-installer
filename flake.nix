{ description = (
    "Work In Progress: a collection of Nix things that are used in more than one project, but aren't refined enough to be standalone libraries/modules/... (yet)."
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-unstable"; };
    config = { type = "github"; owner = "NiklasGollenstede"; repo = "nix-wiplib"; dir = "example/defaultConfig"; };

}; outputs = inputs: let patches = {

    nixpkgs = [
        ./patches/nixpkgs-test.patch # after »nix build«, check »result/inputs/nixpkgs/patched!« to see that these patches were applied
        ./patches/nixpkgs-fix-systemd-boot-install.patch
    ];

}; in (import "${./.}/lib/flakes.nix" "${./.}/lib" inputs).patchFlakeInputsAndImportRepo inputs patches ./. (inputs@ { self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let

    systemsFlake = lib.wip.mkSystemsFalke (rec {
        #systems = { dir = "${./.}/hosts"; exclude = [ ]; };
        inherit inputs;
        scripts = [ ./example/install.sh.md ] ++ (lib.attrValues lib.wip.setup-scripts);
    });

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo
    (if true then systemsFlake else { })
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: {
        packages = lib.wip.getModifiedPackages (lib.wip.importPkgs inputs { system = localSystem; }) overlays;
        defaultPackage = systemsFlake.packages.${localSystem}.all-systems;
    }))
    { patches = import "${./.}/patches" "${./.}/patches" inputs; }
]); }
