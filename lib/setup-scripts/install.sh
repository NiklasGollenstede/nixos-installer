
##
# NixOS Installation
##

## Entry point to the installation, see »./README.md«.
function install-system {( set -o pipefail -u # (void)
    trap - EXIT # start with empty traps for sub-shell
    prepare-installer || exit
    do-disk-setup "${argv[0]}" || exit
    install-system-to $mnt || exit
)}

## Does some argument validation, performs some sanity checks, includes a hack to make installation work when nix isn't installed for root, and runs the installation in qemu (if requested).
function prepare-installer { # (void)

    : ${argv[0]:?"Required: Target disk or image paths."}

    umask g-w,o-w # Ensure that files created without explicit permissions are not writable for group and other (0022).

    if [[ "$(id -u)" != '0' ]] ; then
        if [[ ! ${args[no-vm]:-} ]] ; then reexec-in-qemu || return ; \exit 0 ; fi
        echo 'Script must be run as root or in qemu (without »--no-vm«).' 1>&2 ; \return 1
    fi
    if [[ ${args[vm]:-} ]] ; then reexec-in-qemu || return ; \exit 0 ; fi

    if [[ -e "/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}" ]] ; then echo "Keystore »/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}/« is already open. Close it and remove the mountpoint before running the installer." 1>&2 ; \return 1 ; fi

    # (partitions are checked in »partition-disks« once the target devices are known)
    local luksName ; for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e "/dev/mapper/$luksName" ]] ; then echo "LUKS device mapping »$luksName« is already open. Close it before running the installer." 1>&2 ; \return 1 ; fi
    done
    local poolName ; for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
        if @{native.zfs}/bin/zfs get -o value -H name "$poolName" &>/dev/null ; then echo "ZFS pool »$poolName« is already imported. Export the pool before running the installer." 1>&2 ; \return 1 ; fi
    done

    if [[ ${SUDO_USER:-} && $( PATH=$hostPath which su 2>/dev/null ) ]] ; then # use Nix as the user who called this script, as Nix may not be set up for root
        function nix {( set +x ; declare -a args=("$@") ; PATH=$hostPath su - "$SUDO_USER" -c "$(declare -p args)"' ; nix "${args[@]}"' )}
    else # use Nix by absolute path, as it won't be on »$PATH«
        PATH=$PATH:@{native.nix}/bin
    fi

    _set_x='set -x' ; if [[ ${args[quiet]:-} ]] ; then _set_x=: ; fi

    #if [[ ${args[debug]:-} ]] ; then set +e ; set -E ; trap 'code= ; timeout .2s cat &>/dev/null || true ; @{native.bashInteractive}/bin/bash --init-file @{config.environment.etc.bashrc.source} || code=$? ; if [[ $code ]] ; then exit $code ; fi' ERR ; fi # On error, instead of exiting straight away, open a shell to allow diagnosing/fixing the issue. Only exit if that shell reports failure (e.g. CtrlC + CtrlD). Unfortunately, the exiting has to be repeated for each level of each nested sub-shells. The »timeout cat« eats anything lined up on stdin, which would otherwise be sent to bash and interpreted as commands.

    export PATH=$PATH:@{native.util-linux}/bin # Doing a system installation requires a lot of stuff from »util-linux«. This should probably be moved into the individual functions that actually use the tools ...

}

## Re-executes the current system's installation in a qemu VM.
function reexec-in-qemu {

    if [[ @{pkgs.buildPackages.system} != "@{native.system}" ]] ; then echo "VM installation (implicit when not running as root) of a system built on a different ISA than the current host's is not supported (yet)." 1>&2 ; \return 1 ; fi

    # (not sure whether this works for block devices)
    ensure-disks "${argv[0]}" 1 || return
    qemu=( -m 2048 ) ; declare -A qemuDevs=( )
    local index=2 ; local name ; for name in "${!blockDevs[@]}" ; do
        #if [[ ${blockDevs[$name]} != /dev/* ]] ; then
        qemu+=( # not sure how correct the interpretations of the command are
            -drive format=raw,file="$( realpath "${blockDevs[$name]}" )",media=disk,if=none,index=${index},id=drive${index} # create the disk drive, without attaching it, name it driveX
            #-device ahci,acpi-index=${index},id=ahci${index} # create an (ich9-)AHCI bus named »ahciX«
            #-device ide-hd,drive=drive${index},bus=ahci${index}.${index} # attach IDE?! disk driveX as device X on bus »ahciX«
            -device virtio-blk-pci,drive=drive${index},disable-modern=on,disable-legacy=off # alternative to the two lines above (implies to be faster, but seems to require guest drivers)
        )
        qemuDevs[$name]=/dev/vd$( printf "\x$(printf %x $(( index - 1 + 97 )) )" ) # a is used by the (unused) root disk
        let index+=1
    done

    args[vm]='' ; args[no-vm]=1
    newArgs=( ) ; for arg in "${!args[@]}" ; do newArgs+=( --"$arg"="${args[$arg]}" ) ; done
    devSpec= ; for name in "${!qemuDevs[@]}" ; do devSpec+="$name"="${qemuDevs[$name]}": ; done
    newArgs+=( ${devSpec%:} ) ; (( ${#argv[@]} > 1 )) && args+=( "${argv[@]:1}" )

    #local output=@{inputs.self}'#'nixosConfigurations.@{outputName:?}.config.system.build.vmExec
    local output=@{config.system.build.vmExec.drvPath!unsafeDiscardStringContext} # this is more accurate, but also means another system needs to get evaluated every time
    local scripts=$0 ; if [[ @{pkgs.system} != "@{native.system}" ]] ; then
        scripts=$( build-lazy @{inputs.self}'#'apps.@{pkgs.system}.@{outputName:?}.derivation )
    fi
    local command="$scripts install-system $( printf '%q ' "${newArgs[@]}" ) || exit"

    local runInVm ; runInVm=$( build-lazy $output )/bin/run-@{config.system.name}-vm-exec || return

    $runInVm ${args[vm-shared]:+--shared="${args[vm-shared]}"} ${args[debug]:+--initrd-console} ${args[trace]:+--initrd-console} ${args[quiet]:+--quiet} -- "$command" "${qemu[@]}" || return # --initrd-console
}


## The default command that will activate the system and install the bootloader. In a separate function to make it easy to replace.
function nixos-install-cmd {( set -eu # 1: mnt, 2: topLevel
    # »nixos-install« by default does some stateful things (see »--no-root-passwd« »--no-channel-copy«), builds and copies the system config, registers the system (»nix-env --profile /nix/var/nix/profiles/system --set $targetSystem«), and then calls »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- $topLevel/bin/switch-to-configuration boot«, which is essentially the same as »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- @{config.system.build.installBootLoader} $targetSystem«, i.e. the side effects of »nixos-enter« and then calling the bootloader-installer.

    #PATH=@{config.systemd.package}/bin:@{native.nix}/bin:$PATH TMPDIR=/tmp LC_ALL=C @{native.nixos-install-tools}/bin/nixos-install --system "$2" --no-root-passwd --no-channel-copy --root "$1" || exit # We did most of this, so just install the bootloader:

    export NIXOS_INSTALL_BOOTLOADER=1 # tells some bootloader installers (systemd & grub) to not skip parts of the installation
    @{native.nixos-install-tools}/bin/nixos-enter --silent --root "$1" -- @{config.system.build.installBootLoader} "$2" || exit
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

    # Support cross architecture installation (not sure if this is actually required)
    if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{config.wip.preface.hardware}"-linux ]] ; then
        mkdir -p $mnt/run/binfmt || exit ; [[ ! -e /run/binfmt/"@{config.wip.preface.hardware}"-linux ]] || cp -a {,$mnt}/run/binfmt/"@{config.wip.preface.hardware}"-linux || exit # On NixOS, this is a symlink or wrapper script, pointing to the store.
        # Ubuntu (20.04, by default) uses a statically linked, already loaded qemu binary (F-flag), which therefore does not need to be reference-able from within the chroot.
    fi

    # Copy system closure to new nix store:
    if [[ ${SUDO_USER:-} ]] ; then chown -R $SUDO_USER: $mnt/nix/store $mnt/nix/var || exit ; fi
    cmd=( nix --extra-experimental-features nix-command --offline copy --no-check-sigs --to $mnt ${topLevel:-$targetSystem} )
    if [[ ${args[quiet]:-} ]] ; then
        "${cmd[@]}" --quiet >/dev/null 2> >( grep -Pe '^error:' || true ) || exit
    elif  [[ ${args[quiet]:-} ]] ; then
        ( set -x ; time "${cmd[@]}" ) || exit
    else
        ( set -x ; "${cmd[@]}" ) || exit
    fi
    rm -rf $mnt/nix/var/nix/gcroots || exit
    # TODO: if the target has @{config.nix.settings.auto-optimise-store} and the host doesn't (there is no .links dir?), optimize now
    if [[ ${SUDO_USER:-} ]] ; then chown -R root:root $mnt/nix $mnt/nix/var || exit ; chown :30000 $mnt/nix/store || exit ; fi

    # Set this as the initial system generation (in case »nixos-install-cmd« won't):
    # (does about the same as »nix-env --profile /nix/var/nix/profiles/system --set $targetSystem«)
    mkdir -p -m 755 $mnt/nix/var/nix/{profiles,gcroots}/per-user/root/ || exit
    ln -sT $(realpath $targetSystem) $mnt/nix/var/nix/profiles/system-1-link || exit
    ln -sT system-1-link $mnt/nix/var/nix/profiles/system || exit
    ln -sT /nix/var/nix/profiles $mnt/nix/var/nix/gcroots/profiles || exit

    # Run the main install command (primarily for the bootloader):
    mount -o bind,ro /nix/store $mnt/nix/store || exit ; prepend_trap '! mountpoint -q $mnt/nix/store || umount -l $mnt/nix/store' EXIT || exit # all the things required to _run_ the system are copied, but (may) need some more things to initially install it and/or enter the chroot (like qemu, see above)
    run-hook-script 'Pre Installation' @{config.wip.fs.disks.preInstallCommands!writeText.preInstallCommands} || exit
    code=0 ; nixos-install-cmd $mnt "${topLevel:-$targetSystem}" >$beLoud 2>$beSilent || code=$?
    run-hook-script 'Post Installation' @{config.wip.fs.disks.postInstallCommands!writeText.postInstallCommands} || exit

    # Done!
    if [[ ${args[no-inspect]:-} ]] ; then
        if (( code != 0 )) ; then \exit $code ; fi
    elif [[ ${args[inspect-cmd]:-} ]] ; then
        if (( code != 0 )) ; then \exit $code ; fi
        eval "${args[inspect-cmd]}" || exit
    else
        if (( code != 0 )) ; then
            ( set +x ; echo "Something went wrong in the last step of the installation. Inspect the output above and the mounted system in this chroot shell to decide whether it is critical. Exit the shell with 0 to proceed, or non-zero to abort." 1>&2 )
        else
            ( set +x ; echo "[1;32mInstallation done![0m This shell is in a chroot in the mounted system for inspection. Exiting the shell will unmount the system." 1>&2 )
        fi
        PATH=@{config.systemd.package}/bin:$PATH @{native.nixos-install-tools}/bin/nixos-enter --root $mnt -- /nix/var/nix/profiles/system/sw/bin/bash --login || exit # +o monitor
    fi

    mkdir -p $mnt/var/lib/systemd/timesync && touch $mnt/var/lib/systemd/timesync/clock || true # save current time
)}
