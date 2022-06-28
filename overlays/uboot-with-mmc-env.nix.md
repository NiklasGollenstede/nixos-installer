/*

# U-Boot with Env Compiled and on MMC

A function reconfiguring an u-boot package to save its env on MMC (e.g. internal boot storage or microSD) if it doesn't already, and to compile a custom default env into u-boot itself.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in {

    uboot-with-mmc-env = {
        base ? null,

        # The (maximum) total size, position (each in in bytes), and MMC device number of the u-boot env that can be set later:
        envSize ? base.envSize or 16384,
        envOffset ? base.envOffset or 4194304,
        envMmcDev ? 1,
        # Default boot variables for u-boot. This amends the variables that will be compiled into u-boot as the default env, but also is the base for the variables written by the ».mkEnv« function. As such, this should include everything necessary to boot something:
        defaultEnv ? ({ }), # $src/scripts/get_default_env.sh can read this again
        # Lines to append to the u-boot config:
        extraConfig ? [ ],

    }: base.overrideAttrs (old: let
        envTxt = env: pkgs.writeText "uboot-env.txt" "${lib.concatStrings (lib.mapAttrsToList (k: v: if v == null then "" else "${k}=${toString v}\n") env)}";
		defaultEnv' = (base.defaultEnv or { }) // defaultEnv;
    in {
        passthru = (old.passthru or { }) // {
            inherit envSize envOffset; defaultEnv = defaultEnv';

            # Creates a (user) env blob for this u-boot by merging »env« over its »defaultEnv«. The resulting file can be flashed to »CONFIG_ENV_OFFSET« to replace the default env.
            mkEnv = env: pkgs.runCommandLocal "uboot-env.img" {
                env = envTxt (defaultEnv' // env);
            } "${pkgs.ubootTools}/bin/mkenvimage -p 0x00 -s ${toString envSize} -o $out $env";

        };
        extraConfig = (old.extraConfig or "") + "${lib.concatStringsSep "\n" ([
            # (these need to be passed as 0x<hex>:)
            "CONFIG_ENV_OFFSET=0x${lib.concatStrings (map toString (lib.toBaseDigits 16 envOffset))}"
            "CONFIG_ENV_SIZE=0x${lib.concatStrings (map toString (lib.toBaseDigits 16 envSize))}"
            # Ensure that env is configured to be stored on MMC(/microSD):
            "CONFIG_ENV_IS_IN_MMC=y" "CONFIG_SYS_MMC_ENV_DEV=${toString envMmcDev}" # (not sure this is enough)
            # CONFIG_EXTRA_ENV_SETTINGS here would be overwritten, and CONFIG_DEFAULT_ENV_FILE replaces some basics that should be kept.
        ] ++ extraConfig)}\n";
        CONFIG_EXTRA_ENV_SETTINGS = ''${lib.concatMapStringsSep ''"\0"'' builtins.toJSON (lib.mapAttrsToList (k: v: if v == null then "" else ''${k}=${toString v}'') defaultEnv')}"\0"''; # (this is in addition to whatever u-boot derives from its other CONFIG_*)
        postConfigure = (old.postConfigure or "") + ''
            # Set CONFIG_EXTRA_ENV_SETTINGS just before it's used, to make sure it actually applies:
            printf "%s\n%s\n" "#define CONFIG_EXTRA_ENV_SETTINGS $CONFIG_EXTRA_ENV_SETTINGS" "$(cat include/env_default.h)" >include/env_default.h
        '';
	});
}
