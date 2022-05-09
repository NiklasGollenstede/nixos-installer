dirname: inputs: let

    getNamedScriptFiles = dir: builtins.removeAttrs (builtins.listToAttrs (map (name: let
        match = builtins.match ''^(.*)[.]sh([.]md)?$'' name;
    in if (match != null) then {
        name = builtins.head match; value = "${dir}/${name}";
    } else { name = ""; value = null; }) (builtins.attrNames (builtins.readDir dir)))) [ "" ];

    inherit (inputs.config) prefix;

    replacePrefix = if prefix == "wip" then (x: x) else (builtins.mapAttrs (name: path: (
        builtins.toFile name (builtins.replaceStrings
            [ "@{config.wip."       "@{#config.wip."       "@{!config.wip." ]
            [ "@{config.${prefix}." "@{#config.${prefix}." "@{!config.${prefix}." ]
            (builtins.readFile path)
        )
    )));

in replacePrefix (getNamedScriptFiles dirname)
