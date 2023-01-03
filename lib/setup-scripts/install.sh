
##
# NixOS Installation
##

## Entry point to the installation, see »./README.md«.
function install-system {( set -u # 1: blockDev
    trap - EXIT # start with empty traps for sub-shell
    prepare-installer "$@" || exit
    do-disk-setup "${argv[0]}" || exit
    install-system-to $mnt || exit
)}

## Does very simple argument paring and validation, performs some sanity checks, includes a hack to make installation work when nix isn't installed for root, and enables debugging (if requested).
function prepare-installer { # ...

    generic-arg-parse "$@" || return

    if [[ ${args[debug]:-} ]] ; then set -x ; fi

    : ${argv[0]:?"Required: Target disk or image paths."}

    if [[ "$(id -u)" != '0' ]] ; then echo 'Script must be run as root.' 1>&2 ; return 1 ; fi
    umask 0022 # Ensure consistent umask (default permissions for new files).

    if [[ -e "/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}" ]] ; then echo "Keystore »/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}/« is already open. Close it and remove the mountpoint before running the installer." 1>&2 ; return 1 ; fi

    # (partitions are checked in »partition-disks« once the target devices are known)
    local luksName ; for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e "/dev/mapper/$luksName" ]] ; then echo "LUKS device mapping »$luksName« is already open. Close it before running the installer." 1>&2 ; return 1 ; fi
    done
    local poolName ; for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
        if @{native.zfs}/bin/zfs get -o value -H name "$poolName" &>/dev/null ; then echo "ZFS pool »$poolName« is already imported. Export the pool before running the installer." 1>&2 ; return 1 ; fi
    done

    if [[ ${SUDO_USER:-} ]] ; then # use Nix as the user who called this script, as Nix may not be set up for root
        function nix {( set +x ; declare -a args=("$@") ; PATH=$hostPath su - "$SUDO_USER" -c "$(declare -p args)"' ; nix "${args[@]}"' )}
    else # use Nix by absolute path, as it won't be on »$PATH«
        PATH=$PATH:@{native.nix}/bin
    fi

    _set_x='set -x' ; if [[ ${args[quiet]:-} ]] ; then _set_x=: ; fi

    if [[ ${args[debug]:-} ]] ; then set +e ; set -E ; trap 'code= ; timeout .2s cat &>/dev/null || true ; @{native.bashInteractive}/bin/bash --init-file @{config.environment.etc.bashrc.source} || code=$? ; if [[ $code ]] ; then exit $code ; fi' ERR ; fi # On error, instead of exiting straight away, open a shell to allow diagnosing/fixing the issue. Only exit if that shell reports failure (e.g. CtrlC + CtrlD). Unfortunately, the exiting has to be repeated for each level of each nested sub-shells. The »timeout cat« eats anything lined up on stdin, which would otherwise be sent to bash and interpreted as commands.

    export PATH=$PATH:@{native.util-linux}/bin # Doing a system installation requires a lot of stuff from »util-linux«. This should probably be moved into the individual functions that actually use the tools ...

}

## The default command that will activate the system and install the bootloader. In a separate function to make it easy to replace.
function nixos-install-cmd {( set -eu # 1: mnt, 2: topLevel
    # »nixos-install« by default does some stateful things (see the »--no« options below), builds and copies the system config (but that's already done), and then calls »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- $topLevel/bin/switch-to-configuration boot«, which is essentially the same as »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- @{config.system.build.installBootLoader} $targetSystem«, i.e. the side effects of »nixos-enter« and then calling the bootloader-installer.
    PATH=@{config.systemd.package}/bin:@{native.nix}/bin:$PATH TMPDIR=/tmp LC_ALL=C @{native.nixos-install-tools}/bin/nixos-install --system "$2" --no-root-passwd --no-channel-copy --root "$1" || exit #--debug
)}

## Copies the system's dependencies to the disks mounted at »$mnt« and installs the bootloader. If »$inspect« is set, a root shell will be opened in »$mnt« afterwards.
#  »$topLevel« may point to an alternative top-level dependency to install.
function install-system-to {( set -u # 1: mnt
    mnt=$1 ; topLevel=${2:-}
    targetSystem=${args[toplevel]:-@{config.system.build.toplevel}}
    beLoud=/dev/null ; if [[ ${args[debug]:-} ]] ; then beLoud=/dev/stdout ; fi
    beSilent=/dev/stderr ; if [[ ${args[quiet]:-} ]] ; then beSilent=/dev/null ; fi
    trap - EXIT # start with empty traps for sub-shell

    # Link/create files that some tooling expects:
    mkdir -p -m 755 $mnt/nix/var/nix || exit ; mkdir -p -m 1775 $mnt/nix/store || exit
    mkdir -p $mnt/etc $mnt/run || exit ; mkdir -p -m 1777 $mnt/tmp || exit
    mount tmpfs -t tmpfs $mnt/run || exit ; prepend_trap "umount -l $mnt/run" EXIT || exit # If there isn't anything mounted here, »activate« will mount a tmpfs (inside »nixos-enter«'s private mount namespace). That would hide the additions below.
    [[ -e $mnt/etc/NIXOS ]] || touch $mnt/etc/NIXOS || exit # for »switch-to-configuration«
    [[ -e $mnt/etc/mtab ]] || ln -sfn /proc/mounts $mnt/etc/mtab || exit
    ln -sT $(realpath $targetSystem) $mnt/run/current-system || exit
    #mkdir -p /nix/var/nix/db # »nixos-containers« requires this but nothing creates it before nix is used. BUT »nixos-enter« screams: »/nix/var/nix/db exists and is not a regular file.«

    # If the system configuration is supposed to be somewhere on the system, might as well initialize that:
    if [[ @{config.environment.etc.nixos.source:-} && @{config.environment.etc.nixos.source} != /nix/store/* && @{config.environment.etc.nixos.source} != /run/current-system/config && ! -e $mnt/@{config.environment.etc.nixos.source} && -e $targetSystem/config ]] ; then
        mkdir -p -- $mnt/@{config.environment.etc.nixos.source} || exit
        cp -at $mnt/@{config.environment.etc.nixos.source} -- $targetSystem/config/* || exit
        chown -R 0:0 $mnt/@{config.environment.etc.nixos.source} || exit
        chmod -R u+w $mnt/@{config.environment.etc.nixos.source} || exit
    fi

    # Set this as the initial system generation (just in case »nixos-install-cmd« won't):
    mkdir -p -m 755 $mnt/nix/var/nix/profiles || exit
    [[ -e $mnt/nix/var/nix/profiles/system-1-link ]] || ln -sT $(realpath $targetSystem) $mnt/nix/var/nix/profiles/system-1-link || exit
    [[ -e $mnt/nix/var/nix/profiles/system ]] || ln -sT system-1-link $mnt/nix/var/nix/profiles/system || exit

    # Support cross architecture installation (not sure if this is actually required)
    if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{config.wip.preface.hardware}"-linux ]] ; then
        mkdir -p $mnt/run/binfmt || exit ; [[ ! -e /run/binfmt/"@{config.wip.preface.hardware}"-linux ]] || cp -a {,$mnt}/run/binfmt/"@{config.wip.preface.hardware}"-linux || exit
        # Ubuntu (by default) expects the "interpreter" at »/usr/bin/qemu-@{config.wip.preface.hardware}-static«.
    fi

    # Copy system closure to new nix store:
    if [[ ${SUDO_USER:-} ]] ; then chown -R $SUDO_USER: $mnt/nix/store $mnt/nix/var || exit ; fi
    (
        cmd=( nix --extra-experimental-features nix-command --offline copy --no-check-sigs --to $mnt ${topLevel:-$targetSystem} )
        if [[ ${args[quiet]:-} ]] ; then
            ( set -o pipefail ; "${cmd[@]}" --quiet 2>&1 >/dev/null | { grep -Pe '^error:' || true ; } ) || exit
        else set -x ; time "${cmd[@]}" || exit ; fi
    ) || exit ; rm -rf $mnt/nix/var/nix/gcroots || exit
    # TODO: if the target has @{config.nix.settings.auto-optimise-store} and the host doesn't (there is no .links dir?), optimize now
    if [[ ${SUDO_USER:-} ]] ; then chown -R root:root $mnt/nix $mnt/nix/var || exit ; chown :30000 $mnt/nix/store || exit ; fi

    # Run the main install command (primarily for the bootloader):
    mount -o bind,ro /nix/store $mnt/nix/store || exit ; prepend_trap '! mountpoint -q $mnt/nix/store || umount -l $mnt/nix/store' EXIT || exit # all the things required to _run_ the system are copied, but (may) need some more things to initially install it and/or enter the chroot (like qemu, see above)
    run-hook-script 'Pre Installation' @{config.wip.fs.disks.preInstallCommands!writeText.preInstallCommands} || exit
    code=0 ; nixos-install-cmd $mnt "${topLevel:-$targetSystem}" >$beLoud 2>$beSilent || code=$?
    run-hook-script 'Post Installation' @{config.wip.fs.disks.postInstallCommands!writeText.postInstallCommands} || exit

    # Done!
    if [[ ${args[no-inspect]:-} ]] ; then
        if (( code != 0 )) ; then exit $code ; fi
    elif [[ ${args[inspect-cmd]:-} ]] ; then
        if (( code != 0 )) ; then exit $code ; fi
        eval "${args[inspect-cmd]}" || exit
    else
        if (( code != 0 )) ; then
            ( set +x ; echo "Something went wrong in the last step of the installation. Inspect the output above and the mounted system in this chroot shell to decide whether it is critical. Exit the shell with 0 to proceed, or non-zero to abort." 1>&2 )
        else
            ( set +x ; echo "Installation done! This shell is in a chroot in the mounted system for inspection. Exiting the shell will unmount the system." 1>&2 )
        fi
        PATH=@{config.systemd.package}/bin:$PATH @{native.nixos-install-tools}/bin/nixos-enter --root $mnt || exit # TODO: construct path as it would be at login
        #( cd $mnt ; mnt=$mnt @{native.bashInteractive}/bin/bash --init-file @{config.environment.etc.bashrc.source} )
    fi

    mkdir -p $mnt/var/lib/systemd/timesync && touch $mnt/var/lib/systemd/timesync/clock || true # save current time
)}
