
##
# NixOS Installation
##

declare-command install-system '[--disks=diskPaths]' << 'EOD'
This command installs a NixOS system to local disks or image files.
It gets all the information it needs from the system's NixOS configuration -- except for the path(s) of the target disk(s) / image file(s); see the »--disks=« flag.

Since the installation needs to format and mount (image files as) disks, it needs some way of elevating permissions. It can:
* be run as »root«, requiring Nix to be installed system-wide / for root,
* be run with the »sudo« argument (see »--help« output; this runs »nix« commands as the original user, and the rest as root),
* or automatically perform the installation in a qemu VM (see »--vm« flag).

Installing inside the VM is safer (will definitely only write to the supplied »diskPaths«), more secure (executes everything inside the VM), and does not require privilege elevation, is significantly slower (painfully slow without KVM), and may break custom »*Commands« hooks (esp. those passing in secrets). Across ISAs, the VM installation is even slower, taking many hours for even a simple system.
Without VM, installations across different ISAs (e.g. from an x64 desktop to a Raspberry Pi microSD) works (even relatively fast) if the installing host is NixOS and sets »boot.binfmt.emulatedSystems« for the target systems ISA, or on other Linux with a matching »binfmt_misc« registration with the preload (F) flag.

Once done, the disk(s) can be transferred -- or the image(s) be copied -- to the final system, and should boot there.
If the target host's hardware target allows, a resulting image can also be passed to the »register-vbox« command to create a bootable VirtualBox instance for the current user, or to »run-qemu« to start it in a qemu VM.

What the installation does is defined solely by the target host's NixOS configuration.
The "Installation" section of each host's documentation should contain host specific details, if any.
Various »FLAG«s below affect how the installation is performed (in VM, verbosity, debugging, ...).
EOD
declare-flag install-system,'*' disks "diskPaths" "The disk(s) (to be) used by this system installation.
If »diskPaths« points to something in »/dev/«, then it is directly used as block device, otherwise »diskPaths« is (re-)created as raw image file and then used as loop device.
For hosts that install to multiple disks, pass a colon-separated list of »<disk-name>=<path>« pairs (the name may be omitted only for the "default" disk).
If a directory path ending in a forward slash is passed, it is expanded to ».img« files in that directory, one per (and named after) declared disk.
Defaults to »/tmp/nixos-img-@{config.installer.outputName:-@{config.system.name}}/«."
if [[ ! ${args[disks]:-} ]] ; then args[disks]=/tmp/nixos-img-@{config.installer.outputName:-@{config.system.name}}/ ; fi

function install-system {(
    trap - EXIT # start with empty traps for sub-shell
    prepare-installer || exit
    do-disk-setup || exit
    install-system-to $mnt || exit
)}

declare-flag install-system vm "" "Perform the system installation in a qemu VM instead of on the host itself. This is implied when not running as »root« (or with the »sudo« option).
The VM boots the target system's kernel (or a slight modification of it, if the system kernel is not bootable in qemu) and performs the installation at the end of the first boot stage (instead of mounting the root filesystem and starting systemd).
The target disks or images are passed into the VM as block devices (and are the only devices available there). The host's »/nix/« folder is passed as a read-only network share. This makes the installation safe and secure, but also slower (network share), and may cause problems with custom install commands.
The calling user should have access to KVM, or the installation will be very very slow.
See also the »--no-vm« and »--vm-shared=« flags."
declare-flag install-system no-vm "" "Never perform the installation in a VM. Fail if not executed as »root«."

## Does some argument validation, performs some sanity checks, includes a hack to make installation work when nix isn't installed for root, and runs the installation in qemu (if requested).
function prepare-installer {

    run-hook-script 'Prepare Installer' @{config.installer.commands.prepareInstaller!writeText.prepareInstallerCommands} || exit

    umask g-w,o-w # Ensure that files created without explicit permissions are not writable for group and other.

    if [[ "$(id -u)" != '0' ]] ; then
        if [[ ! ${args[no-vm]:-} ]] ; then exec-in-qemu install-system || return ; \exit 0 ; fi
        echo 'Script must be run as root or in qemu (without »--no-vm«).' 1>&2 ; \return 1
    fi
    if [[ ${args[vm]:-} ]] ; then exec-in-qemu install-system || return ; \exit 0 ; fi

    if [[ -e "/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}" ]] ; then echo "Keystore »/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}/« is already open. Close it and remove the mountpoint before running the installer." 1>&2 ; \return 1 ; fi

    # (partitions are checked in »partition-disks« once the target devices are known)
    local luksName ; for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e "/dev/mapper/$luksName" ]] ; then echo "LUKS device mapping »$luksName« is already open. Close it before running the installer." 1>&2 ; \return 1 ; fi
    done
    local poolName ; for poolName in "@{!config.setup.zfs.pools[@]}" ; do
        if @{native.zfs}/bin/zfs get -o value -H name "$poolName" &>/dev/null ; then echo "ZFS pool »$poolName« is already imported. Export the pool before running the installer." 1>&2 ; \return 1 ; fi
    done

    if [[ ${SUDO_USER:-} && ! $( PATH=$hostPath which nix 2>/dev/null ) && $( PATH=$hostPath which su 2>/dev/null ) ]] ; then # use Nix as the user who called this script, if Nix is not be set up for root
        function nix {( set +x ; declare -a args=("$@") ; PATH=$hostPath su - "$SUDO_USER" -s "@{native.bashInteractive!getExe}" -c "$(declare -p args)"' ; nix "${args[@]}"' )}
    else # use Nix by absolute path, as it won't be on »$PATH«
        PATH=$PATH:@{native.nix}/bin
    fi

    _set_x='set -x' ; if [[ ${args[quiet]:-} ]] ; then _set_x=: ; fi

}

declare-flag install-system vm-shared "dir-path" "When installing inside the VM, specifies a host path that is read-write mounted at »/tmp/shared« inside the VM."
declare-flag install-system vm-args "qemu-args" "When installing inside the VM, extra arguments to pass to qemu."

## (Re-)executes the current system's script in a qemu VM.
function exec-in-qemu { # 1: entry, ...: argv

    qemu=( ) ; apply-vm-args
    args[vm]='' ; args[no-vm]=1

    if [[ ${args[disks]:-} ]] ; then
        # (not sure whether this works for block devices)
        arg_skipLosetup=1 ensure-disks || return
        args[disks]=''
        local index=2 # 1/a is used by the (unused) root disk
        local name ; for name in "${!blockDevs[@]}" ; do
            #if [[ ${blockDevs[$name]} != /dev/* ]] ; then
            qemu+=( # not sure how correct the interpretations of the command are
                -drive format=raw,file="$( realpath "${blockDevs[$name]}" )",media=disk,if=none,index=${index},id=drive${index} # create the disk drive, without attaching it, name it driveX
                #-device ahci,acpi-index=${index},id=ahci${index} # create an (ich9-)AHCI bus named »ahciX«
                #-device ide-hd,drive=drive${index},bus=ahci${index}.${index} # attach IDE?! disk driveX as device X on bus »ahciX«
                -device virtio-blk-pci,drive=drive${index},disable-modern=on,disable-legacy=off # alternative to the two lines above (implies to be faster, but seems to require guest drivers)
            )
            args[disks]+="$name"=/dev/vd"$( printf "\x$(printf %x $(( index - 1 + 97 )) )" )": ; let index+=1
        done
        args[disks]=${args[disks]%:}
    fi

    newArgs=( ) ; (( $# == 0 )) || newArgs+=( "$@" )
    for arg in "${!args[@]}" ; do newArgs+=( --"$arg"="${args[$arg]}" ) ; done

    #local output=@{inputs.self}'#'nixosConfigurations.@{config.installer.outputName:?}.config.system.build.vmExec
    local output=@{config.system.build.vmExec.drvPath!unsafeDiscardStringContext} # this is more accurate, but also means another system needs to get evaluated every time
    if [[ @{pkgs.buildPackages.system} != "@{native.system}" ]] ; then
        echo 'Performing the installation in a cross-ISA qemu system VM; this will be very, very slow (many hours) ...'
        output=@{inputs.self}'#'nixosConfigurations.@{config.installer.outputName:?}.config.system.build.vmExec-@{pkgs.buildPackages.system}
    fi
    local scripts=$self ; if [[ @{pkgs.system} != "@{native.system}" ]] ; then
        scripts=$( build-lazy @{inputs.self}'#'apps.@{pkgs.system}.@{config.installer.outputName:?}.derivation ) || return
    fi
    local command="$scripts $( printf '%q ' "${newArgs[@]}" ) || exit"

    local runInVm ; runInVm=$( build-lazy $output )/bin/run-@{config.system.name}-vm-exec || return

    $runInVm ${args[vm-shared]:+--shared="${args[vm-shared]}"} ${args[debug]:+--initrd-console} ${args[trace]:+--initrd-console} ${args[quiet]:+--quiet} -- "$command" "${qemu[@]}" ${args[vm-args]:-} || return # --initrd-console
}


## The default command that will activate the system and install the bootloader. In a separate function to make it easy to replace.
function nixos-install-cmd {( # 1: mnt, 2: topLevel
    # »nixos-install« by default does some stateful things (see »--no-root-passwd« »--no-channel-copy«), builds and copies the system config, registers the system (»nix-env --profile /nix/var/nix/profiles/system --set $targetSystem«), and then calls »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- $topLevel/bin/switch-to-configuration boot«, which is essentially the same as »NIXOS_INSTALL_BOOTLOADER=1 nixos-enter -- @{config.system.build.installBootLoader} $targetSystem«, i.e. the side effects of »nixos-enter« and then calling the bootloader-installer.

    #PATH=@{native.nix}/bin:$PATH:@{config.systemd.package}/bin TMPDIR=/tmp LC_ALL=C @{native.nixos-install-tools-no-doc}/bin/nixos-install --system "$2" --no-root-passwd --no-channel-copy --root "$1" || exit # We did most of this, so just install the bootloader:

    export NIXOS_INSTALL_BOOTLOADER=1 # tells some bootloader installers (systemd & grub) to not skip parts of the installation
    LC_ALL=C PATH=@{native.busybox}/bin:$PATH:@{native.util-linux}/bin @{native.nixos-install-tools-no-doc}/bin/nixos-enter --silent --root "$1" -c "source /etc/set-environment ; ${_set_x:-:} ; @{config.system.build.installBootLoader} $2" || exit
    # (newer versions of »mount« seem to be unable to do »--make-private« on »rootfs« (in the initrd), but busybox's mount still works)
)}

declare-flag install-system toplevel "store-path" "Optional replacement for the actual »config.system.build.toplevel«."
declare-flag install-system no-inspect "" "Do not inspect the (successfully) installed system before unmounting its filesystems."
declare-flag install-system inspect-cmd "script" "Instead of opening an interactive shell for the post-installation inspection, »eval« this script."

## Copies the system's dependencies to the disks mounted at »$mnt« and installs the bootloader. By default, a root shell will be opened in »$mnt« afterwards.
#  »$topLevel« may point to an alternative top-level dependency to install.
function install-system-to {( set -u # 1: mnt, 2?: topLevel
    targetSystem=${args[toplevel]:-@{config.system.build.toplevel}}
    mnt=$1 ; topLevel=${2:-$targetSystem}
    beLoud=/dev/null ; if [[ ${args[trace]:-} ]] ; then beLoud=/dev/stdout ; fi
    beSilent=/dev/stderr ; if [[ ${args[quiet]:-} ]] ; then beSilent=/dev/null ; fi
    trap - EXIT # start with empty traps for sub-shell

    # Link/create files that some tooling expects:
    mkdir -p -m 755 $mnt/nix/var/nix || exit ; mkdir -p -m 1775 $mnt/nix/store || exit
    mkdir -p $mnt/etc $mnt/run || exit ; mkdir -p -m 1777 $mnt/tmp || exit
    @{native.util-linux}/bin/mount tmpfs -t tmpfs $mnt/run || exit ; prepend_trap "@{native.util-linux}/bin/umount -l $mnt/run" EXIT || exit # If there isn't anything mounted here, »activate« will mount a tmpfs (inside »nixos-enter«'s private mount namespace). That would hide the additions below.
    [[ -e $mnt/etc/NIXOS ]] || touch $mnt/etc/NIXOS || exit # for »nixos-enter«
    [[ -e $mnt/etc/mtab ]] || ln -sfn /proc/mounts $mnt/etc/mtab || exit
    ln -sT $( realpath $targetSystem ) $mnt/run/current-system || exit
    #mkdir -p /nix/var/nix/db # »nixos-containers« requires this but nothing creates it before nix is used. BUT »nixos-enter« screams: »/nix/var/nix/db exists and is not a regular file.«

    # If the system configuration is supposed to be somewhere on the system, might as well initialize that:
    if [[ @{config.environment.etc.nixos.source:-} && @{config.environment.etc.nixos.source} != /nix/store/* && @{config.environment.etc.nixos.source} != /run/current-system/config && ! -e $mnt/@{config.environment.etc.nixos.source} && -e $targetSystem/config ]] ; then
        mkdir -p -- $mnt/@{config.environment.etc.nixos.source} || exit
        cp -at $mnt/@{config.environment.etc.nixos.source} -- $targetSystem/config/* || exit
        chown -R 0:0 $mnt/@{config.environment.etc.nixos.source} || exit
        chmod -R u+w $mnt/@{config.environment.etc.nixos.source} || exit
    fi

    # Support cross architecture installation (not sure if this is actually required)
    if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{pkgs.system}" ]] ; then
        mkdir -p $mnt/run/binfmt || exit ; [[ ! -e /run/binfmt/"@{pkgs.system}" ]] || cp -a {,$mnt}/run/binfmt/"@{pkgs.system}" || exit # On NixOS, this is a symlink or wrapper script, pointing to the store.
        # Ubuntu (20.04, by default) uses a statically linked, already loaded qemu binary (F-flag), which therefore does not need to be reference-able from within the chroot.
    fi

    # Copy system closure to new nix store:
    if declare -f nix >&/dev/null ; then chown -R $SUDO_USER: $mnt/nix/store $mnt/nix/var || exit ; fi
    cmd=( nix --extra-experimental-features nix-command --offline copy --no-check-sigs --to $mnt "$topLevel" )
    if [[ ${args[quiet]:-} ]] ; then
        "${cmd[@]}" --quiet >/dev/null 2> >( grep -Pe '^error:' || true ) || exit
    elif  [[ ${args[quiet]:-} ]] ; then
        ( set -x ; time "${cmd[@]}" ) || exit
    else
        ( set -x ; "${cmd[@]}" ) || exit
    fi
    rm -rf $mnt/nix/var/nix/gcroots || exit
    # TODO: if the target has @{config.nix.settings.auto-optimise-store} and the host doesn't (there is no .links dir?), optimize now
    if declare -f nix >&/dev/null ; then chown -R root:root $mnt/nix $mnt/nix/var || exit ; chown :30000 $mnt/nix/store || exit ; fi

    # Set this as the initial system generation (in case »nixos-install-cmd« won't):
    # (does about the same as »nix-env --profile /nix/var/nix/profiles/system --set $targetSystem«)
    mkdir -p -m 755 $mnt/nix/var/nix/{profiles,gcroots}/per-user/root/ || exit
    ln -sT $(realpath $targetSystem) $mnt/nix/var/nix/profiles/system-1-link || exit
    ln -sT system-1-link $mnt/nix/var/nix/profiles/system || exit
    ln -sT /nix/var/nix/profiles $mnt/nix/var/nix/gcroots/profiles || exit

    # Run the main install command (primarily for the bootloader):
    @{native.util-linux}/bin/mount -o bind,ro /nix/store $mnt/nix/store || exit ; prepend_trap '! @{native.util-linux}/bin/mountpoint -q $mnt/nix/store || @{native.util-linux}/bin/umount -l $mnt/nix/store' EXIT || exit # all the things required to _run_ the system are copied, but (may) need some more things to initially install it and/or enter the chroot (like qemu, see above)
    run-hook-script 'Pre Installation' @{config.installer.commands.preInstall!writeText.preInstallCommands} || exit
    code=0 ; nixos-install-cmd $mnt "$topLevel" >$beLoud 2>$beSilent || code=$?
    run-hook-script 'Post Installation' @{config.installer.commands.postInstall!writeText.postInstallCommands} || exit

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
        LC_ALL=C PATH=@{native.busybox}/bin:$PATH:@{native.util-linux}/bin @{native.nixos-install-tools-no-doc}/bin/nixos-enter --root $mnt -- /nix/var/nix/profiles/system/sw/bin/bash -c 'source /etc/set-environment ; NIXOS_INSTALL_BOOTLOADER=1 CHROOT_DIR="'"$mnt"'" mnt=/ exec "'"$self"'" bash' || exit # +o monitor
    fi

    mkdir -p $mnt/var/lib/systemd/timesync && touch $mnt/var/lib/systemd/timesync/clock || true # save current time
)}
