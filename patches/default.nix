# Returns an attrset where the values are the paths to all ».patch« files in this directory, and the names the respective »basename -s .patch«s.
dirname: inputs: let
    getNamedPatchFiles = dir: builtins.removeAttrs (builtins.listToAttrs (map (name: let
        match = builtins.match ''^(.*)[.]patch$'' name;
    in if (match != null) then {
        name = builtins.head match; value = builtins.path { path = "${dir}/${name}"; inherit name; }; # »builtins.path« puts the file in a separate, content-addressed store path, ensuring it's path only changes when the content changes, thus avoiding unnecessary rebuilds.
    } else { name = ""; value = null; }) (builtins.attrNames (builtins.readDir dir)))) [ "" ];
in (getNamedPatchFiles dirname)
