dirname: inputs@{ self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
    inherit (import "${dirname}/vars.nix" dirname inputs) mapMergeUnique mergeAttrsRecursive endsWith;
    inherit (import "${dirname}/misc.nix" dirname inputs) trace;
in rec {

    # Builds an attrset that, for each folder that contains a »default.nix«, and for each ».nix« or ».nix.md« file in »dir«, maps the the name of that folder, or the name of the file without extension(s), to its full path.
    getNixFiles = dir: mapMergeUnique (name: type: if (type == "directory") then (
        if (builtins.pathExists "${dir}/${name}/default.nix") then { ${name} = "${dir}/${name}/default.nix"; } else { }
    ) else (
        let
            match = builtins.match ''^(.*)[.]nix([.]md)?$'' name;
        in if (match != null) then {
            ${builtins.head match} = "${dir}/${name}";
        } else { }
    )) (builtins.readDir dir);

    getNixFilesRecursive = dir: let
        list = prefix: dir: mapMergeUnique (name: type: if (type == "directory") then (
            list "${prefix}${name}/" "${dir}/${name}"
        ) else (let
            match = builtins.match ''^(.*)[.]nix([.]md)?$'' name;
        in if (match != null) then {
            "${prefix}${builtins.head match}" = "${dir}/${name}";
        } else { })) (builtins.readDir dir);
    in list "" dir;

    ## Decides whether a thing is probably a NixOS configuration module or not.
    #  Probably because almost everything could be a module declaration (any attribute set or function returning one is potentially a module).
    #  Per convention, modules (at least those declared stand-alone in a file) are declared as functions taking at least the named arguments »config«, »pkgs«, and »lib«. Once entered into the module system, to remember where they came from, modules get wrapped in an attrset »{ _file = "<path>"; imports = [ <actual_module> ]; }«.
    isProbablyModule = thing: let args = builtins.functionArgs thing; in (
        (builtins.isFunction thing) && (builtins.isAttrs (thing args)) && (builtins.isBool (args.config or null)) && (builtins.isBool (args.lib or null)) && (builtins.isBool (args.pkgs or null))
    ) || (
        (builtins.isAttrs thing) && ((builtins.attrNames thing) == [ "_file" "imports" ]) && ((builtins.isString thing._file) || (builtins.isPath thing._file)) && (builtins.isList thing.imports)
    );

    ## Decides whether a thing could be a NixPkgs overlay.
    #  Any function with two (usually unnamed) arguments returning an attrset could be an overlay, so that's rather vague.
    couldBeOverlay = thing: let result1 = thing (builtins.functionArgs thing); result2 = result1 (builtins.functionArgs result1); in builtins.isFunction thing && builtins.isFunction result1 && builtins.isAttrs result2;

    # Builds an attrset that, for each folder (containing a »default.nix«) or ».nix« or ».nix.md« file (other than »./default.nix«) in this folder, as the name of that folder or the name of the file without extension(s), exports the result of importing that file/folder.
    importAll = inputs: dir: builtins.mapAttrs (name: path: import path (if endsWith "/default.nix" path then "${dir}/${name}" else dir) inputs) (builtins.removeAttrs (getNixFiles dir) [ "default" ]);

    # Import a Nix file that expects the standard `dirname: inputs: ` arguments, providing some additional information and error handling.
    importWrapped = inputs: path: rec {
        # Whether the file is imported by an explicit full path (or one omitting ».nix« or »/default.nix«):
        isExplicit = (builtins.match ''^(.*)[.]nix([.]md)?$'' path) != null;
        # Whether the import path _implicitly_ refers to the »/default.nix« in a directory:
        isImplicitDir = !isExplicit && builtins.pathExists "${path}/default.nix";
        # The resolved path that will be imported:
        fullPath = if isImplicitDir then "${path}/default.nix" else if isExplicit then path else "${path}.nix";
        # The imported nix value:
        result = import fullPath (if isImplicitDir then path else builtins.dirOf path) inputs;
        # Whether the import path points to an existing file:
        exists = isImplicitDir || (builtins.pathExists (if isExplicit then path else "${path}.nix"));
        # Return »null« if not ».exists«:
        optional = if exists then result else null;
        # Throw if not ».exists«:
        required = if exists then result else throw (if isExplicit then "File ${path} does not exist" else "Neither ${path}/default.nix nor ${path}.nix exist");
        # ».result« interpreted as NixOS module, wrapped to preserve the import path:
        module = { _file = fullPath; imports = [ required ]; };
    };

    ## Returns an attrset that, for each file in »dir« (except ...), imports that file and exposes only if the result passes »filter«. If provided, the imported value is »wrapped« after filtering.
    #  If a file/folder' import that is rejected by »filter« is an attrset (for example because it results from a call to this function), then all attributes whose values pass »filter« are prefixed with the file/folders name plus a slash and merged into the overall attrset.
    #  Example: Given a file tree like this, where each »default.nix« contains only a call to this function with the containing directory as »dir«, and every other file contains a definition of something accepted by the »filter«:
    #     ├── default.nix
    #     ├── a.nix.md
    #     ├── b.nix
    #     └── c
    #         ├── default.nix
    #         ├── d.nix
    #         └── e.nix.md
    # The top level »default.nix« returns:
    # { "a" = <filtered>; "b" = <filtered>; "c/d" = <filtered>; "c/e" = <filtered>; }
    importFilteredFlattened = dir: inputs: { except ? [ ], filter ? (thing: true), wrap ? (path: thing: thing), }: let
        files = builtins.removeAttrs (getNixFiles dir) except;
    in mapMergeUnique (name: path: let
        thing = import path (if endsWith "/default.nix" path then "${dir}/${name}" else dir) inputs;
    in if (filter thing) then (
        { ${name} = wrap path thing; }
    ) else (if (builtins.isAttrs thing) then (
        mapMergeUnique (name': thing': if (filter thing') then (
            { "${name}/${name'}" = thing'; }
        ) else { }) thing
    ) else { })) files;

    # Used in a »default.nix« and called with the »dir« it is in, imports all modules in that directory as attribute set. See »importFilteredFlattened« and »isProbablyModule« for details.
    importModules = inputs: dir: opts: importFilteredFlattened dir inputs ({ except = [ "default" ]; } // opts // { filter = isProbablyModule; wrap = path: module: { _file = path; imports = [ module ]; }; });

    # Used in a »default.nix« and called with the »dir« it is in, imports all overlays in that directory as attribute set. See »importFilteredFlattened« and »couldBeOverlay« for details.
    importOverlays = inputs: dir: opts: importFilteredFlattened dir inputs ({ except = [ "default" ]; } // opts // { filter = couldBeOverlay; });

    # Imports »inputs.nixpkgs« and instantiates it with all ».overlay(s)« provided by »inputs.*«.
    importPkgs = inputs: args: import inputs.nixpkgs ({
        overlays = builtins.concatLists (map (input: if input?overlay then [ input.overlay ] else if input?overlays then builtins.attrValues input.overlays else [ ]) (builtins.attrValues inputs));
    } // args);

    # Given a list of »overlays« and »pkgs« with them applied, returns the subset of »pkgs« that was directly modified by the overlays.
    getModifiedPackages = pkgs: overlays: let
        names = builtins.concatLists (map (overlay: builtins.attrNames (overlay { } { })) (builtins.attrValues overlays));
    in mapMergeUnique (name: if lib.isDerivation pkgs.${name} then { ${name} = pkgs.${name}; } else { }) names;

    ## Given a path to a module in »nixpkgs/nixos/modules/«, when placed in another module's »imports«, this adds an option »disableModule.${modulePath}« that defaults to being false, but when explicitly set to »true«, disables all »config« values set by the module.
    #  Every module should, but not all modules do, provide such an option themselves.
    #  This is similar to adding the path to »disabledModules«, but:
    #  * leaves the module's other definitions (options, imports) untouched, preventing further breakage due to missing options
    #  * makes the disabling an option, i.e. it can be changed dynamically based on other config values
    makeNixpkgsModuleConfigOptional = specialArgs: modulePath: let
        fullPath = "${specialArgs.inputs.nixpkgs.outPath}/nixos/modules/${modulePath}";
        moduleArgs = { utils = import "${specialArgs.inputs.nixpkgs.outPath}/nixos/lib/utils.nix" { inherit (specialArgs) lib config pkgs; }; } // specialArgs;
        module = import fullPath moduleArgs;
    in { _file = fullPath; imports = [
        { options.disableModule.${modulePath} = lib.mkOption { description = "Disable the nixpkgs module ${modulePath}"; type = lib.types.bool; default = false; }; }
        (if module?config then (
            module // { config = lib.mkIf (!specialArgs.config.disableModule.${modulePath}) module.config; }
        ) else (
            { config = lib.mkIf (!specialArgs.config.disableModule.${modulePath}) module; }
        ))
        { disabledModules = [ modulePath ]; }
    ]; };

    ## Given a path to a module, and a function that takes the instantiation of the original module and returns a partial module as override, this recursively applies that override to the original module definition.
    #  Used as an »imports« entry, this allows for much more fine-grained overriding of the configuration (or even other parts) of a module than »makeNixpkgsModuleConfigOptional«, but the override function needs to be tailored to internal implementation details of the original module.
    #  Esp. it is important to know that »mkIf« both existing in the original module and in the return from the override results in an attrset »{ _type="if"; condition; content; }«. Accessing content of an existing »mkIf« thus requires adding ».content« to the lookup path, and the »content« of returned »mkIf«s will get merged with any existing attribute of that name.
    overrideNixpkgsModule = specialArgs: modulePath: override: let
        fullPath = "${specialArgs.inputs.nixpkgs.outPath}/nixos/modules/${modulePath}";
        moduleArgs = { utils = import "${specialArgs.inputs.nixpkgs.outPath}/nixos/lib/utils.nix" { inherit (specialArgs) lib config pkgs; }; } // specialArgs;
        module = import fullPath moduleArgs;
    in { _file = fullPath; imports = [
        (mergeAttrsRecursive ([ { imports = module.imports or [ ]; options = module.options or { }; config = module.config or { }; } ] ++ (lib.toList (override module))))
        { disabledModules = [ modulePath ]; }
    ]; };
}
