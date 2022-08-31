
##
# NixOS Maintenance
##

## On the host and for the user it is called by, creates/registers a VirtualBox VM meant to run the shells target host. Requires the path to the target host's »diskImage« as the result of running the install script. The image file may not be deleted or moved. If »bridgeTo« is set (to a host interface name, e.g. as »eth0«), it is added as bridged network "Adapter 2" (which some hosts need).
function register-vbox {( set -eu # 1: diskImages, 2?: bridgeTo
    diskImages=$1 ; bridgeTo=${2:-}
    vmName="nixos-@{config.networking.hostName}"
    VBoxManage=$( PATH=$hostPath which VBoxManage ) # The host is supposed to run these anyway, and »pkgs.virtualbox« is marked broken on »aarch64«.

    $VBoxManage createvm --name "$vmName" --register --ostype Linux26_64
    $VBoxManage modifyvm "$vmName" --memory 2048 --pae off --firmware efi

    $VBoxManage storagectl "$vmName" --name SATA --add sata --portcount 4 --bootable on --hostiocache on

    index=0 ; for decl in ${diskImages//:/ } ; do
        diskImage=${decl/*=/}
        if [[ ! -e $diskImage.vmdk ]] ; then
            $VBoxManage internalcommands createrawvmdk -filename $diskImage.vmdk -rawdisk $diskImage # pass-through
        fi
        $VBoxManage storageattach "$vmName" --storagectl SATA --port $(( index++ )) --device 0 --type hdd --medium $diskImage.vmdk
    done

    if [[ $bridgeTo ]] ; then # VBoxManage list bridgedifs
        $VBoxManage modifyvm "$vmName" --nic2 bridged --bridgeadapter2 $bridgeTo
    fi

    # The serial settings between qemu and vBox seem incompatible. With a simple »console=ttyS0«, vBox hangs on start. So just disable this for now an use qemu for headless setups. The UX here is awful anyway.
   #$VBoxManage modifyvm "$vmName" --uart1 0x3F8 4 --uartmode1 server /run/user/$(id -u)/$vmName.socket # (guest sets speed)

    set +x # avoid double-echoing
    echo '# VM info:'
    echo " VBoxManage showvminfo $vmName"
    echo '# start VM:'
    echo " VBoxManage startvm $vmName --type headless"
    echo '# kill VM:'
    echo " VBoxManage controlvm $vmName poweroff"
   #echo '# create TTY:'
   #echo " socat UNIX-CONNECT:/run/user/$(id -u)/$vmName.socket PTY,link=/run/user/$(id -u)/$vmName.pty"
   #echo '# connect TTY:'
   #echo " screen /run/user/$(id -u)/$vmName.pty"
    echo '# screenshot:'
    echo " ssh $(@{native.inetutils}/bin/hostname) VBoxManage controlvm $vmName screenshotpng /dev/stdout | display"
)}

## Runs a host in QEMU, taking the same disk specification as the installer. It infers a number of options from he target system's configuration.
#  Currently, this only works for x64 (on x64) ...
function run-qemu {( set -eu # 1: diskImages
    generic-arg-parse "$@"
    diskImages=${argv[0]}
    if [[ ${args[debug]:-} ]] ; then set -x ; fi

    qemu=( @{native.qemu_full}/bin/qemu-system-@{config.wip.preface.hardware} )
    qemu+=( -m ${args[mem]:-2048} -smp ${args[smp]:-4} )

    if [[ @{config.wip.preface.hardware}-linux == "@{native.system}" && ! ${args[no-kvm]:-} ]] ; then
        qemu+=( -cpu host -enable-kvm ) # For KVM to work vBox may not be running anything at the same time (and vBox hangs on start if qemu runs). Pass »--no-kvm« and accept ~10x slowdown, or stop vBox.
    elif [[ @{config.wip.preface.hardware} == aarch64 ]] ; then # assume it's a raspberry PI (or compatible)
        # TODO: this does not work yet:
        qemu+=( -machine type=raspi3b -m 1024 ) ; args[no-nat]=1
        # ... and neither does this:
        #qemu+=( -M virt -m 1024 -smp 4 -cpu cortex-a53  ) ; args[no-nat]=1
    fi # else things are going to be quite slow

    disks=( ${diskImages//:/ } ) ; for index in ${!disks[@]} ; do
#       qemu+=( -drive format=raw,if=ide,file="${disks[$index]/*=/}" ) # »if=ide« is the default, which these days isn't great for driver support inside the VM
        qemu+=( # not sure how correct the interpretations if the command are, and whether this works for more than one disk
            -drive format=raw,file="${disks[$index]/*=/}",media=disk,if=none,index=${index},id=drive${index} # create the disk drive, without attaching it, name it driveX
            -device ahci,acpi-index=${index},id=ahci${index} # create an (ich9-)AHCI bus named »ahciX«
            -device ide-hd,drive=drive${index},bus=ahci${index}.${index} # attach IDE?! disk driveX as device X on bus »ahciX«
            #-device virtio-blk-pci,drive=drive${index},disable-modern=on,disable-legacy=off # alternative to the two lines above (implies to be faster, but seems to require guest drivers)
        )
    done

    if [[ @{config.boot.loader.systemd-boot.enable} || ${args[efi]:-} ]] ; then # UEFI. Otherwise it boots something much like a classic BIOS?
        ovmf=$( @{native.nixVersions.nix_2_9}/bin/nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths @{inputs.nixpkgs}'#'legacyPackages.@{pkgs.system}.OVMF.fd )
        #qemu+=( -bios ${ovmf}/FV/OVMF.fd ) # This works, but is a legacy fallback that stores the EFI vars in /NvVars on the EFI partition (which is really bad).
        qemu+=( -drive file=${ovmf}/FV/OVMF_CODE.fd,if=pflash,format=raw,unit=0,readonly=on )
        qemu+=( -drive file="${args[efi-vars]:-/tmp/qemu-@{config.networking.hostName}-VARS.fd}",if=pflash,format=raw,unit=1 )
        if [[ ! -e "${args[efi-vars]:-/tmp/qemu-@{config.networking.hostName}-VARS.fd}" ]] ; then cat ${ovmf}/FV/OVMF_VARS.fd > "${args[efi-vars]:-/tmp/qemu-@{config.networking.hostName}-VARS.fd}" ; fi
        # https://lists.gnu.org/archive/html/qemu-discuss/2018-04/msg00045.html
    fi
    if [[ @{config.wip.preface.hardware} == aarch64 ]] ; then
        qemu+=( -kernel @{config.system.build.kernel}/Image -initrd @{config.system.build.initialRamdisk}/initrd -append "$(echo -n "@{config.boot.kernelParams[@]}")" )
    fi

    # Add »config.boot.kernelParams = [ "console=tty1" "console=ttyS0" ]« to log to serial (»ttyS0«) and/or the display (»tty1«), preferring the last »console« option for the initrd shell (if enabled and requested).
    logSerial= ; if [[ ' '"@{config.boot.kernelParams[@]}"' ' == *' console=ttyS0'@( |,)* ]] ; then logSerial=1 ; fi
    logScreen= ; if [[ ' '"@{config.boot.kernelParams[@]}"' ' == *' console=tty1 '* ]] ; then logScreen=1 ; fi
    if [[ ! ${args[no-serial]:-} && $logSerial ]] ; then
        if [[ $logScreen || ${args[graphic]:-} ]] ; then
            qemu+=( -serial mon:stdio )
        else
            qemu+=( -nographic ) # Without »console=tty1« or no »console=...« parameter, boot messages won't be on the screen.
        fi
    fi

    if [[ ! ${args[no-nat]:-} ]] ; then # e.g. --nat-fw=8000-:8000,8001-:8001
        qemu+=( -nic user,model=virtio-net-pci${args[nat-fw]:+,hostfwd=tcp::${args[nat-fw]//,/,hostfwd=tcp::}} ) # NATed, IPs: 10.0.2.15+/32, gateway: 10.0.2.2
    fi

    # TODO: network bridging:
    #[[ @{config.networking.hostId} =~ ^(.)(.)(.)(.)(.)(.)(.)(.)$ ]] ; mac=$( printf "52:54:%s%s:%s%s:%s%s:%s%s" "${BASH_REMATCH[@]:1}" )
    #qemu+=( -netdev bridge,id=enp0s3,macaddr=$mac -device virtio-net-pci,netdev=hn0,id=nic1 )

    # To pass a USB device (e.g. a YubiKey for unlocking), add pass »--usb-port=${bus}-${port}«, where bus and port refer to the physical USB port »/sys/bus/usb/devices/${bus}-${port}« (see »lsusb -tvv«). E.g.: »--usb-port=3-1.1.1.4«
    if [[ ${args[usb-port]:-} ]] ; then for decl in ${args[usb-port]//:/ } ; do
        qemu+=( -usb -device usb-host,hostbus="${decl/-*/}",hostport="${decl/*-/}" )
    done ; fi

    if [[ ${args[dry-run]:-} ]] ; then
        ( echo "${qemu[@]}" )
    else
        ( set -x ; "${qemu[@]}" )
    fi

    # https://askubuntu.com/questions/54814/how-can-i-ctrl-alt-f-to-get-to-a-tty-in-a-qemu-session

)}

## Creates a random static key on a new key partition on the GPT partitioned »$blockDev«. The drive can then be used as headless but removable disk unlock method.
#  To create/clear the GPT: $ sgdisk --zap-all "$blockDev"
function add-bootkey-to-keydev {( set -eu # 1: blockDev, 2?: hostHash
    blockDev=$1 ; hostHash=${2:-@{config.networking.hostName!hashString.sha256}}
    bootkeyPartlabel=bootkey-${hostHash:0:8}
    @{native.gptfdisk}/bin/sgdisk --new=0:0:+1 --change-name=0:"$bootkeyPartlabel" --typecode=0:0000 "$blockDev" # create new 1 sector (512b) partition
    @{native.parted}/bin/partprobe "$blockDev" ; @{native.systemd}/bin/udevadm settle -t 15 # wait for partitions to update
    </dev/urandom tr -dc 0-9a-f | head -c 512 >/dev/disk/by-partlabel/"$bootkeyPartlabel"
)}

## Tries to open and mount the systems keystore from its LUKS partition. If successful, adds the traps to close it when the parent shell exits.
#  See »open-system«'s implementation for some example calls to this function.
function mount-keystore-luks { # ...: cryptsetupOptions
    # (For the traps to work, this can't run in a sub shell. The function therefore can't use »( set -eu ; ... )« internally and instead has to use »&&« after every command and in place of most »;«, and the function can't be called from a pipeline.)
    keystore=keystore-@{config.networking.hostName!hashString.sha256:0:8} &&
    mkdir -p -- /run/$keystore &&
    @{native.cryptsetup}/bin/cryptsetup open "$@" /dev/disk/by-partlabel/$keystore $keystore &&
    mount -o nodev,umask=0077,fmask=0077,dmask=0077,ro /dev/mapper/$keystore /run/$keystore &&
    prepend_trap "umount /run/$keystore ; @{native.cryptsetup}/bin/cryptsetup close $keystore ; rmdir /run/$keystore" EXIT
}

## Performs any steps necessary to mount the target system at »/tmp/nixos-install-@{config.networking.hostName}« on the current host.
#  For any steps taken, it also adds the reaps to undo them on  exit from the calling shell, and it always adds the exit trap to do the unmounting itself.
#  »diskImages« may be passed in the same format as to the installer. If so, any image files are ensured to be loop-mounted.
#  Perfect to inspect/update/amend/repair a system's installation afterwards, e.g.:
#  $ source ${config_wip_fs_disks_initSystemCommands1writeText_initSystemCommands}
#  $ source ${config_wip_fs_disks_restoreSystemCommands1writeText_restoreSystemCommands}
#  $ install-system-to /tmp/nixos-install-${config_networking_hostName}
#  $ nixos-enter --root /tmp/nixos-install-${config_networking_hostName}
function open-system { # 1?: diskImages
    # (for the traps to work, this can't run in a sub shell, so also can't »set -eu«, so use »&&« after every command and in place of most »;«)

    local diskImages=${1:-} # If »diskImages« were specified and they point at files that aren't loop-mounted yet, then loop-mount them now:
    local images=$( losetup --list --all --raw --noheadings --output BACK-FILE )
    local decl && for decl in ${diskImages//:/ } ; do
        local image=${decl/*=/} && if [[ $image != /dev/* ]] && ! <<<$images grep -xF $image ; then
            local blockDev=$( losetup --show -f "$image" ) && prepend_trap "losetup -d '$blockDev'" EXIT &&
            @{native.parted}/bin/partprobe "$blockDev" &&
        :;fi &&
    :;done &&
    ( @{native.systemd}/bin/udevadm settle -t 15 || true ) && # sometimes partitions aren't quite made available yet

    if [[ @{config.wip.fs.keystore.enable} && ! -e /dev/mapper/keystore-@{config.networking.hostName!hashString.sha256:0:8} ]] ; then # Try a bunch of approaches for opening the keystore:
        mount-keystore-luks --key-file=<( printf %s "@{config.networking.hostName}" ) ||
        mount-keystore-luks --key-file=/dev/disk/by-partlabel/bootkey-@{config.networking.hostName!hashString.sha256:0:8} ||
        mount-keystore-luks --key-file=<( read -s -p PIN: pin && echo ' touch!' >&2 && ykchalresp -2 "$pin" ) ||
        # TODO: try static yubikey challenge
        mount-keystore-luks
    fi &&

    local mnt=/tmp/nixos-install-@{config.networking.hostName} && if [[ ! -e $mnt ]] ; then mkdir -p "$mnt" && prepend_trap "rmdir '$mnt'" EXIT ; fi &&

    open-luks-layers && # Load crypt layers and zfs pools:
    if [[ $( LC_ALL=C type -t ensure-datasets ) == 'function' ]] ; then
        local poolName && for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
            if ! zfs get -o value -H name "$poolName" &>/dev/null ; then
                zpool import -f -N -R "$mnt" "$poolName" && prepend_trap "zpool export '$poolName'" EXIT &&
            :;fi &&
            : | zfs load-key -r "$poolName" || true &&
        :;done &&
        ensure-datasets "$mnt" &&
    :;fi &&

    prepend_trap "unmount-system '$mnt'" EXIT && mount-system "$mnt" &&

    true # (success)
}
