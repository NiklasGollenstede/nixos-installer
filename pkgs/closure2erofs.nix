dirname: inputs:  let lib = inputs.self.lib.__internal__; in {
    ## Generates a script that writes Nix store closure to an EROFS image (in the expectation that that image will be mounted as /nix/store).
    #  Either a list of root »paths« or a »closureInfo« (as »closure«) can be passed via ».override«, or the path to a »closureInfo« can be supplied as the first argument when executing the script.
    #  The other run-time arguments are passed to »mkfs.erofs« and should specify the output file.
    paths ? null, closure ? if paths == null then null else closureInfo { rootPaths = paths; },

    writeShellScript, closureInfo,
    gnutar, erofs-utils, fetchurl,
}@args: let

    erofs-utils = lib.fun.pinPackage {
        base = args.erofs-utils; version = "1.9.1"; downgrade = false;
        overrideSrc = (src: fetchurl { inherit (src) url; hash = "sha256-qe9atnxLjS0+ntcfOc0Ai9plMUKnINijlaNvERDQxDI="; });
    };

# TODO: passing the files via tar has the advantage that files are only read once, and that we can be explicit about the file metadata, but it does not necessarily pass the files to mkfs.erofs in the order it wants them in -- it will either need to buffer them in memory, or store them out of order.
in writeShellScript "mkfs.erofs" '' # bash
    closure=${closure}
    if [[ ! $closure ]]; then closure=$1 ; shift ; fi
    tar=(
        ${gnutar}/bin/tar --create
        --verbatim-files-from --absolute-names
        --files-from $closure/store-paths
        --transform 'flags=rSh;s|/nix/store/||'
        --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g' # When storing components on a case-insensitive filesystem (MacOS), Nix can add suffixes that allow storing files with names that would otherwise collide. This removes those suffixes.
    )
    erofs=(
        ${erofs-utils}/bin/mkfs.erofs --tar=f
        --force-uid=0 --force-gid=0 -T1 # fixed ownership and timestamps
        -U clear # no UUID, may be overridden by $@
        --hard-dereference # TODO: meaning?
    )
    "''${tar[@]}" | "''${erofs[@]}" "$@"
''
