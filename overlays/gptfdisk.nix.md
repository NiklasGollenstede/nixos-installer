/*

# sGdisk with Patches

GPT-FDisk patched to be able to move not only the primary, but also the backup partition table.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; lib = inputs.self.lib.__internal__;
    debug = false;
    enable = lib.versionOlder prev.gptfdisk.version "1.0.10"; # patch merged in that version
in {

    gptfdisk = if !enable then prev.gptfdisk else (
        if debug then pkgs.enableDebugging else (x: x)
    ) (prev.gptfdisk.overrideAttrs (old: let
        pname = "gptfdisk";
    in rec {
        version = "1.0.9";
        src = builtins.fetchurl {
            url = "https://downloads.sourceforge.net/gptfdisk/${pname}-${version}.tar.gz";
            sha256 = "1hjh5m77fmfq5m44yy61kchv7mbfgx026aw3jy5qxszsjckavzns";
        };
        patches = [ # (don't include »old.patches«, as the only one was upstreamed in v1.0.9)
            ../patches/gptfdisk-move-secondary-table.patch
        ];
    } // (if debug then {
        dontStrip = true;
    } else { })));

    libblockdev = prev.libblockdev.override (lib.optionalAttrs enable { inherit (prev) gptfdisk; });

}
