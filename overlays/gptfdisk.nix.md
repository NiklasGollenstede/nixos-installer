/*

# sGdisk with Patches

GPT-FDisk patched to be able to move not only the primary, but also the backup partition table.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in {

    gptfdisk = prev.gptfdisk.overrideAttrs (old: rec {
        pname = "gptfdisk";
        version = "1.0.9";
        src = builtins.fetchurl {
            url = "https://downloads.sourceforge.net/gptfdisk/${pname}-${version}.tar.gz";
            sha256 = "1hjh5m77fmfq5m44yy61kchv7mbfgx026aw3jy5qxszsjckavzns";
        };
        patches = [ # (don't include »old.patches«, as the only one was upstreamed)
            ../patches/gptfdisk-move-secondary-table.patch
        ];
    });

    libblockdev = prev.libblockdev.override { inherit (prev) gptfdisk; };

}
