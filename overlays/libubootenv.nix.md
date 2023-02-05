/*

# `libubootenv` - Library to access U-Boot environment

As an `environment.systemPackages` entry this provides the `fw_printenv` / `fw_setenv` commands to work with U-Boot's environment variables.


## Example

Assuming `/dev/disk/by-partlabel/config-${...}` is placed at the same location that U-Boot was configured (via `CONFIG_ENV_OFFSET` and `CONFIG_ENV_SIZE`) to expect/save the environment:
```nix
{
    environment.systemPackages = [ pkgs.libubootenv ];
    environment.etc."fw_env.config".text = "/dev/disk/by-partlabel/config-${...} 0x0 0x${lib.concatStrings (map toString (lib.toBaseDigits 16 envSize))}";
}
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in {

    libubootenv = pkgs.stdenv.mkDerivation rec {
        pname = "libubootenv"; version = "0.3.2";

        src = pkgs.fetchFromGitHub {
            owner = "sbabic"; repo = pname; rev = "ba7564f5006d09bec51058cf4f5ac90d4dc18b3c"; # 2018-11-18
            hash = "sha256-6cHkr3s7/2BVXBTn9bUfPFbYAfv9VYh6C9GAbWILNjs=";
        };
        nativeBuildInputs = [ pkgs.buildPackages.cmake ];
        buildInputs = [ pkgs.zlib ];
        outputs = [ "out" "lib" ];

        meta = {
            homepage = "https://github.com/sbabic/libubootenv";
            description = "Generic library and tools to access and modify U-Boot environment from User Space";
            license = [ lib.licenses.lgpl21Plus lib.licenses.mit lib.licenses.cc0 ];
            maintainers = [ ];
            platforms = lib.platforms.linux;
        };
    };
}
