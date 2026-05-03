dirname: inputs:  let lib = inputs.self.lib.__internal__; in {
    writeShellScript, closureInfo,
    gnutar, erofs-utils, fetchurl,
    paths ? null, closure ? if paths == null then null else closureInfo { rootPaths = paths; },
}@args: let

    upgradeIfOlder = pkg: version: getSrc: finalize: if lib.versionAtLeast pkg.version version then pkg else (if finalize == null then _:_ else finalize) ((pkg.overrideAttrs {
        inherit version; __intentionallyOverridingVersion = true;
    }).overrideAttrs (old: { src = getSrc old.src; }));

    erofs-utils = /* lib.fun. */upgradeIfOlder args.erofs-utils "1.9.1" (src: (
        fetchurl { inherit (src) url; hash = "sha256-qe9atnxLjS0+ntcfOc0Ai9plMUKnINijlaNvERDQxDI="; }
    )) null;

in writeShellScript "mkfs.erofs" ''
    closure=${closure}
    if [[ ! $closure ]]; then closure=$1 ; shift ; fi
    tar=(
        ${gnutar}/bin/tar --create
        --verbatim-files-from --absolute-names
        --files-from $closure/store-paths
        --transform 'flags=rSh;s|/nix/store/||'
        --transform 'flags=rSh;s|~nix~case~hack~[[:digit:]]\+||g'
    )
    erofs=(
        ${erofs-utils}/bin/mkfs.erofs --tar=f
        --force-uid=0 --force-gid=0 -T1 # fixed ownership and timestamps\
        -U clear # no UUID, may be overridden
        --hard-dereference # TODO: meaning?
    )
    "''${tar[@]}" | "''${erofs[@]}" "$@"
''
