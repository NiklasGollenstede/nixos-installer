# Returns an attrset where the values are the paths to all ».patch« files in this directory, and the names the respective »basename -s .patch«s.
dirname: inputs: let
    getNamedPatchFiles = dir: builtins.removeAttrs (builtins.listToAttrs (map (name: let
        match = builtins.match ''^(.*)[.]patch$'' name;
    in if (match != null) then {
        name = builtins.head match; value = "${dir}/${name}";
    } else { name = ""; value = null; }) (builtins.attrNames (builtins.readDir dir)))) [ "" ];
in (getNamedPatchFiles dirname) // {
    # When referring to the patches by a path derived from »dirname«, then their paths change whenever that changes, which happens when any file in this repo changes. Changing patch paths mean that the derivations the patches are inputs to need to be rebuilt, so using local paths, which put their targets into a new store artifact (i.e. separate input) is much more efficient.
    # TODO: automate this, somehow:
    nixpkgs-fix-systemd-boot-install = ./nixpkgs-fix-systemd-boot-install.patch;
    nixpkgs-test = ./nixpkgs-test.patch;
}
