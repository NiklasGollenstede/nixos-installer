dirname: inputs@{ self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
    inherit (import "${dirname}/vars.nix" dirname inputs) startsWith;
in rec {

    ## Logic Flow

    notNull = value: value != null;

    ifNull      = value: default:   (if   value == null then default else value);
    withDefault = default: value:   (if   value == null then default else value);
    passNull = mayNull: expression: (if mayNull == null then null    else expression);


    ## Misc

    # Creates a package for `config.systemd.packages` that adds an `override.conf` to the specified `unit` (which is the only way to modify a single service template instance).
    mkSystemdOverride = pkgs: unit: text: (pkgs.runCommandNoCC unit { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p $out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/"}
        <<<${lib.escapeShellArg text} cat >$out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/override.conf"}
    '');

    # Given a message and any value, traces both the message and the value, and returns the value.
    trace = message: value: (builtins.trace (message +": "+ (lib.generators.toPretty { } value)) value);

}
