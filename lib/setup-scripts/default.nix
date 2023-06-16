dirname: inputs: let

    inherit (inputs.config.rename) setup installer;

    doRenames = if setup == "setup" && installer == "installer" then (x: x) else (builtins.mapAttrs (name: path: (
        builtins.toFile name (builtins.replaceStrings
            [ "@{config.setup."    "@{#config.setup."    "@{!config.setup."    "@{config.installer."    "@{#config.installer."    "@{!config.installer."    ]
            [ "@{config.${setup}." "@{#config.${setup}." "@{!config.${setup}." "@{config.${installer}." "@{#config.${installer}." "@{!config.${installer}." ]
            (builtins.readFile path)
        )
    )));

in doRenames (inputs.functions.lib.getFilesExt "sh(.md)?" dirname)
