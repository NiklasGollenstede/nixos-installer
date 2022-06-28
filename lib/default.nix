dirname: inputs@{ self, nixpkgs, ...}: let
    #fix = f: let x = f x; in x;
    #categories = fix (wip: (import "${dirname}/imports.nix" dirname inputs).importAll (inputs // { self = inputs.self // { lib = nixpkgs.lib // { inherit wip; }; }; })) dirname;
    categories = (import "${dirname}/imports.nix" dirname inputs).importAll inputs dirname;
    wip = (builtins.foldl' (a: b: a // b) { } (builtins.attrValues (builtins.removeAttrs categories [ "setup-scripts" ]))) // categories;
in nixpkgs.lib // { wip = wip // { prefix = inputs.config.prefix; }; }
