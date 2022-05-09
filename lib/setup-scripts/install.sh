
##
# NixOS Installation
##

## Ensures that the installer gets called by root and with an argument, includes a hack to make installation work when nix isn't installed for root, and enables debugging (if requested).
function prepare-installer { # ...

    beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then set -x ; beQuiet=/dev/stdout ; fi

    if [[ "$(id -u)" != '0' ]] ; then echo 'Script must be run in a root (e.g. in a »sudo --preserve-env=SSH_AUTH_SOCK -i«) shell.' ; exit ; fi
    if [[ ${SUDO_USER:-} ]] ; then function nix {( args=("$@") ; su - "$SUDO_USER" -c "$(declare -p args)"' ; nix "${args[@]}"' )} ; fi

    : ${1:?"Required: Target disk or image paths."}

    if [[ $debug ]] ; then set +e ; set -E ; trap 'code= ; bash -l || code=$? ; if [[ $code ]] ; then exit $code ; fi' ERR ; fi # On error, instead of exiting straight away, open a shell to allow diagnosing/fixing the issue. Only exit if that shell reports failure (e.g. CtrlC + CtrlD). Unfortunately, the exiting has to be repeated for level of each nested sub-shells.

}

## Copies the system's dependencies to the disks mounted at »$mnt« and installs the bootloader. If »$inspect« is set, a root shell will be opened in »$mnt« afterwards.
#  »$topLevel« may point to an alternative top-level dependency to install.
function install-system-to {( # 1: mnt, 2?: inspect, 3?: topLevel
	mnt=$1 ; inspect=${2:-} ; topLevel=${3:-}
	targetSystem=@{config.system.build.toplevel}
	trap - EXIT # start with empty traps for sub-shell

	for dir in dev/ sys/ run/ ; do mkdir -p $mnt/$dir ; mount tmpfs -t tmpfs $mnt/$dir ; prepend_trap "while umount -l $mnt/$dir 2>$beQuiet ; do : ; done" EXIT ; done # proc/ run/
	mkdir -p -m 755 $mnt/nix/var ; mkdir -p -m 1775 $mnt/nix/store
	if [[ ${SUDO_USER:-} ]] ; then chown $SUDO_USER: $mnt/nix/store $mnt/nix/var ; fi

	( set -x ; time nix copy --no-check-sigs --to $mnt ${topLevel:-$targetSystem} )
	ln -sT $(realpath $targetSystem) $mnt/run/current-system
	mkdir -p -m 755 $mnt/nix/var/nix/profiles  ; ln -sT $(realpath $targetSystem) $mnt/nix/var/nix/profiles/system
	mkdir -p $mnt/etc/ ; [[ -e $mnt/etc/NIXOS ]] || touch $mnt/etc/NIXOS

	if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{config.preface.hardware}"-linux ]] ; then # cross architecture installation
	    mkdir -p $mnt/run/binfmt ; cp -a {,$mnt}/run/binfmt/"@{config.preface.hardware}"-linux || true
	    # Ubuntu (by default) expects the "interpreter" at »/usr/bin/qemu-@{config.preface.hardware}-static«.
	fi

	if [[ ${SUDO_USER:-} ]] ; then chown -R root:root $mnt/nix ; chown :30000 $mnt/nix/store ; fi

	mount -o bind /nix/store $mnt/nix/store # all the things required to _run_ the system are copied, but (may) need some more things to initially install it
	code=0 ; TMPDIR=/tmp LC_ALL=C nixos-install --system ${topLevel:-$targetSystem} --no-root-passwd --no-channel-copy --root $mnt || code=$? #--debug
	umount -l $mnt/nix/store

	if [[ $inspect ]] ; then
		if (( code != 0 )) ; then
		    ( set +x ; echo "Something went wrong in the last step of the installation. Inspect the output above and the system mounted in CWD to decide whether it is critical. Exit the shell with 0 to proceed, or non-zero to abort." )
		else
		    ( set +x ; echo "Installation done, but the system is still mounted in CWD for inspection. Exit the shell to unmount it." )
		fi
		( cd $mnt ; mnt=$mnt bash -l )
	fi

	( mkdir -p $mnt/var/lib/systemd/timesync ; touch $mnt/var/lib/systemd/timesync/clock ) || true # save current time
)}
