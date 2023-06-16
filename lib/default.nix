dirname: inputs@{ nixpkgs, functions, ...}: let
    categories = functions.lib.importAll inputs dirname;
    self = (builtins.foldl' (a: b: a // (if builtins.isAttrs b then b else { })) { } (builtins.attrValues (builtins.removeAttrs categories [ "setup-scripts" ]))) // categories;
in self // { __internal__ = nixpkgs.lib // { self = self; fun = functions.lib; }; }
