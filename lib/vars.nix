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

    # If »exp« (which mustn't match across »\n«) matches (a part of) exactly one line in »text«, return that »line« including tailing »\n«, plus the text part »before« and »after«, and the text »without« the line.
    extractLine = exp: text: let split = builtins.split "([^\n]*${exp}[^\n]*\n)" (builtins.unsafeDiscardStringContext text); get = builtins.elemAt split; ctxify = str: lib.addContextFrom text str; in if builtins.length split != 3 then null else rec { before = ctxify (get 0); line = ctxify (builtins.head (get 1)); after = ctxify (get 2); without = ctxify (before + after); }; # (TODO: The string context stuff is actually required, but why? Shouldn't »builtins.split« propagate the context?)

    # Given a string, returns its first/last char (or last utf-8(?) byte?).
    firstChar = string: builtins.substring                                (0) 1 string;
    lastChar  = string: builtins.substring (builtins.stringLength string - 1) 1 string;

    startsWith = prefix: string: let length = builtins.stringLength prefix; in (builtins.substring                                     (0) (length) string) == prefix;
    endsWith   = suffix: string: let length = builtins.stringLength suffix; in (builtins.substring (builtins.stringLength string - length) (length) string) == suffix;

    removeTailingNewline = string: if lastChar string == "\n" then builtins.substring 0 (builtins.stringLength string - 1) string else string;


    ## Math

    pow = (let pow = b: e: if e == 1 then b else if e == 0 then 1 else b * pow b (e - 1); in pow); # (how is this not an operator or builtin?)

    toBinString = int: builtins.concatStringsSep "" (map builtins.toString (lib.toBaseDigits 2 int));

    parseSizeSuffix = decl: let
        match = builtins.match ''^([0-9]+)(K|M|G|T|P)?(i)?(B)?$'' decl;
        num = lib.toInt (builtins.head match); unit = builtins.elemAt match 1;
        exponent = if unit == null then 0 else { K = 1; M = 2; G = 3; t = 4; P = 5; }.${unit};
        base = if (builtins.elemAt match 3) == null || (builtins.elemAt match 2) != null then 1024 else 1000;
    in if builtins.isInt decl then decl else if match != null then num * (pow base exponent) else throw "${decl} is not a number followed by a size suffix";

}
