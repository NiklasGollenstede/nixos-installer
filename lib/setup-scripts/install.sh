
##
# NixOS Installation
##

## Entry point to the installation, see »./README.md«.
function install-system {( set -eu # 1: blockDev
    prepare-installer "$@"
    do-disk-setup "${argv[0]}"
    init-or-restore-system
    install-system-to $mnt
)}

## Does very simple argument passing and validation, performs some sanity checks, includes a hack to make installation work when nix isn't installed for root, and enables debugging (if requested).
function prepare-installer { # ...

    generic-arg-parse "$@"

    beQuiet=/dev/null ; if [[ ${args[debug]:-} ]] ; then set -x ; beQuiet=/dev/stdout ; fi

    : ${argv[0]:?"Required: Target disk or image paths."}

    if [[ "$(id -u)" != '0' ]] ; then echo 'Script must be run as root.' ; exit 1 ; fi
    umask 0022 # Ensure consistent umask (default permissions for new files).

    if [[ -e "/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}" ]] ; then echo "Keystore »/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}/« is already open. Close it and remove the mountpoint before running the installer." ; exit 1 ; fi

    # (partitions are checked in »partition-disks« once the target devices are known)
    local luksName ; for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e "/dev/mapper/$luksName" ]] ; then echo "LUKS device mapping »$luksName« is already open. Close it before running the installer." ; exit 1 ; fi
    done
    local poolName ; for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
        if zfs get -o value -H name "$poolName" &>/dev/null ; then echo "ZFS pool »$poolName« is already imported. Export the pool before running the installer." ; exit 1 ; fi
    done

    if [[ ${SUDO_USER:-} ]] ; then function nix {( set +x ; declare -a args=("$@") ; PATH=/bin:/usr/bin su - "$SUDO_USER" -c "$(declare -p args)"' ; nix "${args[@]}"' )} ; fi

    if [[ ${args[debug]:-} ]] ; then set +e ; set -E ; trap 'code= ; @{native.bashInteractive}/bin/bash --init-file @{config.environment.etc.bashrc.source} || code=$? ; if [[ $code ]] ; then exit $code ; fi' ERR ; fi # On error, instead of exiting straight away, open a shell to allow diagnosing/fixing the issue. Only exit if that shell reports failure (e.g. CtrlC + CtrlD). Unfortunately, the exiting has to be repeated for level of each nested sub-shells.

}

## Depending on the presence or absence of the »--restore« CLI flag, either runs the system's initialization or restore commands.
#  The initialization commands are expected to create files that can't be stored in the (host's or target system's) nix store (i.e. secrets).
#  The restore commands are expected to pull in a backup of the systems secrets and state from somewhere, and need to acknowledge that something happened by running »restore-supported-callback«.
function init-or-restore-system {( set -eu # (void)
    if [[ ! ${args[restore]:-} ]] ; then
        run-hook-script 'System Initialization' @{config.wip.fs.disks.initSystemCommands!writeText.postPartitionCommands} # TODO: Do this later inside the chroot?
        return # usually, this would be it ...
    fi
    requiresRestoration=$(mktemp) ; trap "rm -f '$requiresRestoration'" EXIT ; function restore-supported-callback {( rm -f "$requiresRestoration" )}
    run-hook-script 'System Restoration' @{config.wip.fs.disks.restoreSystemCommands!writeText.postPartitionCommands}
    if [[ -e $requiresRestoration ]] ; then echo 'The »restoreSystemCommands« did not call »restore-supported-callback« to mark backup restoration as supported for this system. Assuming incomplete configuration.' 1>&2 ; exit 1 ; fi
)}

## The default command that will activate the system and install the bootloader. In a separate function to make it easy to replace.
function nixos-install-cmd {( set -eu # 1: mnt, 2: topLevel
    # »nixos-install« by default does some stateful things (see the »--no« options below), builds and copies the system config (but that's already done), and then calls »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- $topLevel/bin/switch-to-configuration boot«, which is essentially the same as »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- @{config.system.build.installBootLoader} $targetSystem«, i.e. the side effects of »nixos-enter« and then calling the bootloader-installer.
    PATH=@{config.systemd.package}/bin:$PATH TMPDIR=/tmp LC_ALL=C nixos-install --system "$2" --no-root-passwd --no-channel-copy --root "$1" #--debug
)}

## Copies the system's dependencies to the disks mounted at »$mnt« and installs the bootloader. If »$inspect« is set, a root shell will be opened in »$mnt« afterwards.
#  »$topLevel« may point to an alternative top-level dependency to install.
function install-system-to {( set -eu # 1: mnt, 2?: topLevel
    mnt=$1 ; topLevel=${2:-}
    targetSystem=@{config.system.build.toplevel}
    trap - EXIT # start with empty traps for sub-shell

    # Copy system closure to new nix store:
    mkdir -p -m 755 $mnt/nix/var/nix ; mkdir -p -m 1775 $mnt/nix/store
    if [[ ${SUDO_USER:-} ]] ; then chown -R $SUDO_USER: $mnt/nix/store $mnt/nix/var ; fi
    ( set -x ; time nix copy --no-check-sigs --to $mnt ${topLevel:-$targetSystem} ) ; rm -rf $mnt/nix/var/nix/gcroots
    if [[ ${SUDO_USER:-} ]] ; then chown -R root:root $mnt/nix $mnt/nix/var ; chown :30000 $mnt/nix/store ; fi

    # Link/create files that some tooling expects:
    mkdir -p $mnt/etc $mnt/run ; mkdir -p -m 1777 $mnt/tmp
    mount tmpfs -t tmpfs $mnt/run ; prepend_trap "umount -l $mnt/run" EXIT # If there isn't anything mounted here, »activate« will mount a tmpfs (inside »nixos-enter«'s private mount namespace). That would hide the additions below.
    [[ -e $mnt/etc/NIXOS ]] || touch $mnt/etc/NIXOS # for »switch-to-configuration«
    [[ -e $mnt/etc/mtab ]] || ln -sfn /proc/mounts $mnt/etc/mtab
    ln -sT $(realpath $targetSystem) $mnt/run/current-system
    #mkdir -p /nix/var/nix/db # »nixos-containers« requires this but nothing creates it before nix is used. BUT »nixos-enter« screams: »/nix/var/nix/db exists and is not a regular file.«

    # Set this as the initial system generation:
    mkdir -p -m 755 $mnt/nix/var/nix/profiles ; ln -sT $(realpath $targetSystem) $mnt/nix/var/nix/profiles/system-1-link ; ln -sT system-1-link $mnt/nix/var/nix/profiles/system

    # Support cross architecture installation (not sure if this is actually required)
    if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{config.preface.hardware}"-linux ]] ; then
        mkdir -p $mnt/run/binfmt ; cp -a {,$mnt}/run/binfmt/"@{config.preface.hardware}"-linux || true
        # Ubuntu (by default) expects the "interpreter" at »/usr/bin/qemu-@{config.preface.hardware}-static«.
    fi

    # Run the main install command (primarily for the bootloader):
    mount -o bind,ro /nix/store $mnt/nix/store ; prepend_trap '! mountpoint -q $mnt/nix/store || umount -l $mnt/nix/store' EXIT # all the things required to _run_ the system are copied, but (may) need some more things to initially install it
    code=0 ; nixos-install-cmd $mnt "${topLevel:-$targetSystem}" || code=$?
    #umount -l $mnt/nix/store # »nixos-enter« below still needs the bind mount, if installing cross-arch

    # Done!
    if [[ ! ${args[no-inspect]:-} ]] ; then
        if (( code != 0 )) ; then
            ( set +x ; echo "Something went wrong in the last step of the installation. Inspect the output above and the mounted system in this chroot shell to decide whether it is critical. Exit the shell with 0 to proceed, or non-zero to abort." )
        else
            ( set +x ; echo "Installation done! This shell is in a chroot in the mounted system for inspection. Exiting the shell will unmount the system." )
        fi
        PATH=@{config.systemd.package}/bin:$PATH nixos-enter --root $mnt
        #( cd $mnt ; mnt=$mnt @{native.bashInteractive}/bin/bash --init-file @{config.environment.etc.bashrc.source} )
    elif (( code != 0 )) ; then
        exit $code
    fi

    ( mkdir -p $mnt/var/lib/systemd/timesync ; touch $mnt/var/lib/systemd/timesync/clock ) || true # save current time
)}
