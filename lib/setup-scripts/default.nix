dirname: inputs: let

    inherit (inputs.config) prefix;
    inherit (import "${dirname}/../imports.nix" dirname inputs) getFilesExt;

    replacePrefix = if prefix == "wip" then (x: x) else (builtins.mapAttrs (name: path: (
        builtins.toFile name (builtins.replaceStrings
            [ "@{config.wip."       "@{#config.wip."       "@{!config.wip." ]
            [ "@{config.${prefix}." "@{#config.${prefix}." "@{!config.${prefix}." ]
            (builtins.readFile path)
        )
    )));

in replacePrefix (getFilesExt "sh(.md)?" dirname)
