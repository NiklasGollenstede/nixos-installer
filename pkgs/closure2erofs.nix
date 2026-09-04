dirname: inputs:  let lib = inputs.self.lib.__internal__; in {
    ## Generates a script that writes Nix store closure to an EROFS image (in the expectation that that image will be mounted as /nix/store).
    #  Either a list of root »paths« or a »closureInfo« (as »closure«) can be passed via ».override«, or the path to a »closureInfo« can be supplied as the first argument when executing the script.
    #  The other run-time arguments are passed to »mkfs.erofs« and should specify the output file.
    paths ? null, closure ? if paths == null then null else closureInfo { rootPaths = paths; },
    args ? [ ], tarArgs ? [ ], realize ? false,

    writeShellScript, runCommand, closureInfo,
    gnutar, erofs-utils, fetchurl,
}@funcArgs: let

    erofs-utils = lib.fun.pinPackage {
        base = funcArgs.erofs-utils; version = "1.9.1"; downgrade = false;
        overrideSrc = (src: fetchurl { inherit (src) url; hash = "sha256-qe9atnxLjS0+ntcfOc0Ai9plMUKnINijlaNvERDQxDI="; });
    };

    # TODO: passing the files via tar has the advantage that files are only read once, and that we can be explicit about the file metadata, but it does not necessarily pass the files to mkfs.erofs in the order it wants them in -- it will either need to buffer them in memory, or store them out of order.

    script = '' # bash
        closure=${closure}
        if [[ ! $closure ]]; then closure=$1 ; shift ; fi
        tar=(
            ${gnutar}/bin/tar --create
            --verbatim-files-from --absolute-names
            --files-from $closure/store-paths
            --transform 'flags=rSh;s|${builtins.storeDir}/||' # in the (target) paths or (regular) files and hardlinks (but not Symlinks) replace the fist occurrence if the store dir with nothing.
            --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' # When storing components on a case-insensitive filesystem (MacOS), Nix can add suffixes that allow storing files with names that would otherwise collide. This removes those suffixes.
            ${lib.escapeShellArgs tarArgs}
        )
        erofs=(
            ${erofs-utils}/bin/mkfs.erofs --tar=f
            --force-uid=0 --force-gid=0 -T1 # fixed ownership and timestamps
            -U clear # no UUID, may be overridden by $@
            #--hard-dereference # (why would we want to split hardlinks into separate files?)
            ${lib.escapeShellArgs args}
        )
        "''${tar[@]}" | "''${erofs[@]}" "$@"
    '';
in if realize then runCommand "erofs-image" { } ''
    set -u -o pipefail
    set -- $out
    ${script}
'' else writeShellScript "mkfs.erofs" script
