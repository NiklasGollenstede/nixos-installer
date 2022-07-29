dirname: { self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
in rec {

    ## Data Structures

    # Given a function and a list, calls the function for each list element, and returns the merge of all attr sets returned by the function
    # attrs = mapMerge (value: { "${newKey}" = newValue; }) list
    # attrs = mapMerge (key: value: { "${newKey}" = newValue; }) attrs
    mapMerge       = toAttr: listOrAttrs: mergeAttrs       (if builtins.isAttrs listOrAttrs then lib.mapAttrsToList toAttr listOrAttrs else map toAttr listOrAttrs);
    mapMergeUnique = toAttr: listOrAttrs: mergeAttrsUnique (if builtins.isAttrs listOrAttrs then lib.mapAttrsToList toAttr listOrAttrs else map toAttr listOrAttrs);

    # Given a list of attribute sets, returns the merged set of all contained attributes, with those in elements with higher indices taking precedence.
    mergeAttrs = attrsList: builtins.foldl' (a: b: a // b) { } attrsList;

    # Given a list of attribute sets, returns the merged set of all contained attributes. Throws if the same attribute name occurs more than once.
    mergeAttrsUnique = attrsList: let
        merged = mergeAttrs attrsList;
        names = builtins.concatLists (map builtins.attrNames attrsList);
        duplicates = builtins.filter (a: (lib.count (b: a == b) names) >= 2) (builtins.attrNames merged);
    in (
        if (builtins.length (builtins.attrNames merged)) == (builtins.length names) then merged
        else throw "Duplicate key(s) in attribute merge set: ${builtins.concatStringsSep ", " duplicates}"
    );

    mergeAttrsRecursive = attrsList: let # slightly adjusted from https://stackoverflow.com/a/54505212
        merge = attrPath: lib.zipAttrsWith (name: values:
            if builtins.length values == 1
                then builtins.head values
            else if builtins.all builtins.isList values
                then lib.unique (builtins.concatLists values)
            else if builtins.all builtins.isAttrs values
                then merge (attrPath ++ [ name ]) values
            else builtins.elemAt values (builtins.length values - 1)
        );
    in merge [ ] attrsList;

    getListAttr = name: attrs: if attrs != null then ((attrs."${name}s" or [ ]) ++ (if attrs?${name} then [ attrs.${name} ] else [ ])) else [ ];

    repeat = count: element: builtins.genList (i: element) count;

    # Given an attribute set of attribute sets (»{ ${l1name}.${l2name} = value; }«), flips the positions of the first and second name level, producing »{ ${l3name}.${l1name} = value; }«. The set of »l2name«s does not need to be the same for each »l1name«.
    flipNames = attrs: let
        l1names = builtins.attrNames attrs;
        l2names = builtins.concatMap builtins.attrNames (builtins.attrValues attrs);
    in mapMerge (l2name: {
        ${l2name} = mapMerge (l1name: if attrs.${l1name}?${l2name} then { ${l1name} = attrs.${l1name}.${l2name}; } else { }) l1names;
    }) l2names;

    # Like »builtins.catAttrs«, just for attribute sets instead of lists: Given an attribute set of attribute sets (»{ ${l1name}.${l2name} = value; }«) and the »name« of a second-level attribute, this returns the attribute set mapping directly from the first level's names to the second-level's values (»{ ${l1name} = value; }«), omitting any first-level attributes that lack the requested second-level attribute.
    catAttrSets = name: attrs: (builtins.mapAttrs (_: value: value.${name}) (lib.filterAttrs (_: value: value?${name}) attrs));


    ## String Manipulation

    # Given a regular expression with capture groups and a list of strings, returns the flattened list of all the matched capture groups of the strings matched in their entirety by the regular expression.
    mapMatching = exp: strings: (builtins.filter (v: v != null) (builtins.concatLists (builtins.filter (v: v != null) (map (string: (builtins.match exp string)) strings))));
    # Given a regular expression and a list of strings, returns the list of all the strings matched in their entirety by the regular expression.
    filterMatching = exp: strings: (builtins.filter (matches exp) strings);
    filterMismatching = exp: strings: (builtins.filter (string: !(matches exp string)) strings);
    matches = exp: string: builtins.match exp string != null;
    extractChars = exp: string: let match = (builtins.match "^.*(${exp}).*$" string); in if match == null then null else builtins.head match;

    # If »exp« (which mustn't match across »\n«) matches (a part of) exactly one line in »text«, return that »line« including tailing »\n«, plus the text part »before« and »after«, the text »without« the line, and any »captures« made by »exp«. If »text« does not end in a »\n«, then one will be added (since this function operates on lines).
    # The »*Anchored« version allows the expression to require to match from the »start« and/or to the »end« of its line, by passing the respective bool(s) as »true«.
    extractLineAnchored = exp: start: end: text: let
        exp' = "(${if start then "^|\n" else ""})(${if start then "" else "[^\n]*"}(${exp})${if end then "" else "[^\n]*"}\n)"; # First capture group is the optional start anchor, the second one the line itself.
        text' = (builtins.unsafeDiscardStringContext (if (lastChar text) == "\n" then text else text + "\n")); # Ensure tailing newline and drop context (since it needs to be added again anyway).
        split = builtins.split exp' text';
        get = builtins.elemAt split; matches = get 1;
        ctxify = str: lib.addContextFrom text str;
    in if builtins.length split != 3 then null else rec { # length < 3 => no match ; length < 3 => multiple matches
        before = ctxify ((get 0) + (builtins.head matches));
        line = ctxify (builtins.elemAt matches 1);
        captures = map ctxify (lib.sublist 3 (builtins.length matches) matches);
        after = ctxify (get 2);
        without = ctxify (before + after);
    }; # (The string context stuff is actually required, but why? Shouldn't »builtins.split« propagate the context?)
    extractLine = exp: text: extractLineAnchored exp false false text;

    # Given a string, returns its first/last char (or last utf-8(?) byte?).
    firstChar = string: builtins.substring                                (0) 1 string;
    lastChar  = string: builtins.substring (builtins.stringLength string - 1) 1 string;

    startsWith = prefix: string: let length = builtins.stringLength prefix; in (builtins.substring                                     (0) (length) string) == prefix;
    endsWith   = suffix: string: let length = builtins.stringLength suffix; in (builtins.substring (builtins.stringLength string - length) (length) string) == suffix;

    removeTailingNewline = string: if lastChar string == "\n" then builtins.substring 0 (builtins.stringLength string - 1) string else string;

    ## Reproducibly generates a GUID by sha256-hashing a prefixed name. The result looks like a RFC 4122 GUID "generated by [SHA1] hashing a namespace identifier and name".
    #  E.g.: sha256guid "gpt-disk:primary:${hostname}" => "xxxxxxxx-xxxx-5xxx-8xxx-xxxxxxxxxxxx"
    sha256guid = name: let
        hash = builtins.hashString "sha256" "nixos-guid:${name}";
        s = from: to: builtins.substring from (to - from) hash;
    in "${s 0 8}-${s 8 12}-5${s 13 16}-8${s 17 20}-${s 20 32}";


    ## Math

    pow = (let pow = b: e: if e == 1 then b else if e == 0 then 1 else b * pow b (e - 1); in pow); # (how is this not an operator or builtin?)

    toBinString = int: builtins.concatStringsSep "" (map builtins.toString (lib.toBaseDigits 2 int));

    parseSizeSuffix = decl: let
        match = builtins.match ''^([0-9]+)(K|M|G|T|P)?(i)?(B)?$'' decl;
        num = lib.toInt (builtins.head match); unit = builtins.elemAt match 1;
        exponent = if unit == null then 0 else { K = 1; M = 2; G = 3; T = 4; P = 5; }.${unit};
        base = if (builtins.elemAt match 3) == null || (builtins.elemAt match 2) != null then 1024 else 1000;
    in if builtins.isInt decl then decl else if match != null then num * (pow base exponent) else throw "${decl} is not a number followed by a size suffix";

}
