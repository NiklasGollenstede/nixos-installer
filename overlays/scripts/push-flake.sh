# 1: targetStore, 2?: flakePath

set -o pipefail -u
targetStore=${1:?} ; if [[ $targetStore != *://* ]] ; then targetStore='ssh://'$targetStore ; fi
flakePath=$( @{pkgs.coreutils}/bin/realpath "${2:-.}" ) || exit

# TODO: this only considers top-level inputs
# TODO: the names in lock.nodes.* do not necessarily match those in inputs.* (there is the lock.nodes.root mapping)
storePaths=( $( PATH=@{pkgs.git}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' eval --impure --expr 'let
    lock = builtins.fromJSON (builtins.readFile "'"$flakePath"'/flake.lock");
    flake = builtins.getFlake "'"$flakePath"'"; inherit (flake) inputs;
in builtins.concatStringsSep " " ([ flake.outPath ] ++ (map (name: inputs.${name}.outPath) (
    (builtins.filter (name: lock.nodes.${name}.original.type == "indirect") (builtins.attrNames inputs))
)))' --raw ) ) || exit
: ${storePaths[0]:?}

PATH=@{pkgs.openssh}/bin:@{pkgs.hostname-debian}/bin:@{pkgs.gnugrep}/bin:$PATH @{pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes' copy --to "$targetStore" ${storePaths[@]} || exit ; echo ${storePaths[0]}
# ¿¿Why does something there call »hostname -I«, which is apparently only available in the debian version of hostname??
