
##
# NixOS Maintenance
##

## On the host and for the user it is called by, creates/registers a VirtualBox VM meant to run the shells target host. Requires the path to the target host's »diskImage« as the result of running the install script. The image file may not be deleted or moved. If »bridgeTo« is set (to a host interface name, e.g. as »eth0«), it is added as bridged network "Adapter 2" (which some hosts need).
function register-vbox {( # 1: diskImages, 2?: bridgeTo
    diskImages=$1 ; bridgeTo=${2:-}
    vmName="nixos-@{config.networking.hostName}"
    VBoxManage=$( PATH=$hostPath which VBoxManage ) || exit # The host is supposed to run these anyway, and »pkgs.virtualbox« is marked broken on »aarch64«.

    $VBoxManage createvm --name "$vmName" --register --ostype Linux26_64 || exit
    $VBoxManage modifyvm "$vmName" --memory 2048 --pae off --firmware efi || exit

    $VBoxManage storagectl "$vmName" --name SATA --add sata --portcount 4 --bootable on --hostiocache on || exit

    index=0 ; for decl in ${diskImages//:/ } ; do
        diskImage=${decl/*=/}
        if [[ ! -e $diskImage.vmdk ]] ; then
            $VBoxManage internalcommands createrawvmdk -filename $diskImage.vmdk -rawdisk $diskImage || exit # pass-through
            #VBoxManage convertfromraw --format VDI $diskImage $diskImage.vmdk && rm $diskImage # convert
        fi
        $VBoxManage storageattach "$vmName" --storagectl SATA --port $(( index++ )) --device 0 --type hdd --medium $diskImage.vmdk || exit
    done

    if [[ $bridgeTo ]] ; then # VBoxManage list bridgedifs
        $VBoxManage modifyvm "$vmName" --nic2 bridged --bridgeadapter2 $bridgeTo || exit
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
function run-qemu { # 1: diskImages, ...: qemuArgs
    if [[ ${args[install]:-} && ! ${argv[0]:-} ]] ; then argv[0]=/tmp/nixos-vm/@{outputName:-@{config.system.name}}/ ; fi
    diskImages=${argv[0]:?} ; argv=( "${argv[@]:1}" )

    local qemu=( )

    if [[ @{pkgs.system} == "@{native.system}" ]] ; then
        qemu=( $( build-lazy @{native.qemu_kvm.drvPath!unsafeDiscardStringContext} )/bin/qemu-kvm ) || return
        if [[ ! ${args[no-kvm]:-} && -r /dev/kvm && -w /dev/kvm ]] ; then
            # For KVM to work, vBox must not be running anything at the same time (and vBox hangs on start if qemu runs). Pass »--no-kvm« and accept ~10x slowdown, or stop vBox.
            qemu+=( -enable-kvm -cpu host )
            if [[ ! ${args[smp]:-} ]] ; then qemu+=( -smp 4 ) ; fi # else the emulation is single-threaded anyway
        else
            if [[ ! ${args[no-kvm]:-} && ! ${args[quiet]:-} ]] ; then
                echo "KVM is not available (for the current user). Running without hardware acceleration." 1>&2
            fi
            qemu+=( -machine accel=tcg ) # this may suppress warnings that qemu is using tcg (slow) instead of kvm
        fi
    else
        qemu=( $( build-lazy @{native.qemu_full.drvPath!unsafeDiscardStringContext} )/bin/qemu-system-@{config.wip.preface.hardware} ) || return
    fi
    if [[ @{pkgs.system} == aarch64-* ]] ; then
        qemu+=( -machine type=virt ) # aarch64 has no default, but this seems good
    fi ; qemu+=( -cpu max )

    qemu+=( -m ${args[mem]:-2048} )
    if [[ ${args[smp]:-} ]] ; then qemu+=( -smp ${args[smp]} ) ; fi

    if [[ @{config.boot.loader.systemd-boot.enable} || ${args[efi]:-} ]] ; then # UEFI. Otherwise it boots SeaBIOS.
        local ovmf ; ovmf=$( build-lazy @{pkgs.OVMF.drvPath!unsafeDiscardStringContext} fd ) || return
        #qemu+=( -bios ${ovmf}/FV/OVMF.fd ) # This works, but is a legacy fallback that stores the EFI vars in /NvVars on the EFI partition (which is really bad).
        local fwName=OVMF ; if [[ @{pkgs.system} == aarch64-* ]] ; then fwName=AAVMF ; fi # fwName=QEMU
        qemu+=( -drive file=${ovmf}/FV/${fwName}_CODE.fd,if=pflash,format=raw,unit=0,readonly=on )
        local efiVars=${args[efi-vars]:-"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/qemu-@{outputName:-@{config.system.name}}-VARS.fd"}
        qemu+=( -drive file="$efiVars",if=pflash,format=raw,unit=1 )
        if [[ ! -e "$efiVars" ]] ; then mkdir -pm700 "$( dirname "$efiVars" )" ; cat ${ovmf}/FV/${fwName}_VARS.fd >"$efiVars" || return ; fi
        # https://lists.gnu.org/archive/html/qemu-discuss/2018-04/msg00045.html
    fi
#   if [[ @{config.wip.preface.hardware} == aarch64 ]] ; then
#       qemu+=( -kernel @{config.system.build.kernel}/Image -initrd @{config.system.build.initialRamdisk}/initrd -append "$(echo -n "@{config.boot.kernelParams[@]}")" )
#   fi

    if [[ $diskImages == */ ]] ; then
        disks=( ${diskImages}primary.img ) ; for name in "@{!config.wip.fs.disks.devices[@]}" ; do if [[ $name != primary ]] ; then disks+=( ${diskImages}${name}.img ) ; fi ; done
    else disks=( ${diskImages//:/ } ) ; fi

    [[ ' '"@{boot.initrd.availableKernelModules[@]}"' ' != *' 'virtio_blk' '* ]] || args[virtio-blk]=1
    local index ; for index in ${!disks[@]} ; do
#       qemu+=( -drive format=raw,if=ide,file="${disks[$index]/*=/}" ) # »if=ide« is the default, which these days isn't great for driver support inside the VM
        qemu+=( -drive format=raw,file="${disks[$index]/*=/}",media=disk,if=none,index=${index},id=drive${index} ) # create the disk drive, without attaching it, name it driveX

        if [[ ! ${args[virtio-blk]:-} ]] ; then
            qemu+=( -device ahci,acpi-index=${index},id=ahci${index} ) # create an (ich9-)AHCI bus named »ahciX«
            qemu+=( -device ide-hd,drive=drive${index},bus=ahci${index}.${index} ) # attach IDE?! disk driveX as device X on bus »ahciX«
        else
            qemu+=( -device virtio-blk-pci,drive=drive${index},disable-modern=on,disable-legacy=off ) # this should be faster, but seems to require guest drivers
        fi
    done

    if [[ ${args[share]:-} ]] ; then # e.g. --share='foo:/home/user/foo,readonly=on bar:/tmp/bar'
        local share ; for share in ${args[share]} ; do
            qemu+=( -virtfs local,security_model=none,mount_tag=${share/:/,path=} )
            # In the VM: $ mount -t 9p -o trans=virtio -o version=9p2000.L -o msize=4194304 -o ro foo /foo
        done
    fi

    # Add »config.boot.kernelParams = [ "console=tty1" "console=ttyS0" ]« to log to serial (»ttyS0«) and/or the display (»tty1«), preferring the last »console« option for the initrd shell (if enabled and requested).
    local logSerial= ; if [[ ' '"@{config.boot.kernelParams[@]}"' ' == *' console=ttyS0'@( |,)* ]] ; then logSerial=1 ; fi
    local logScreen= ; if [[ ' '"@{config.boot.kernelParams[@]}"' ' == *' console=tty1 '* ]] ; then logScreen=1 ; fi
    if [[ ! ${args[no-serial]:-} && $logSerial ]] ; then
        if [[ $logScreen || ${args[graphic]:-} ]] ; then
            qemu+=( -serial mon:stdio )
        else
            qemu+=( -nographic ) # Without »console=tty1« or no »console=...« parameter, boot messages won't be on the screen.
        fi
    fi

    if [[ ! ${args[no-nat]:-} ]] ; then # e.g. --nat-fw=:8000-:8000,:8001-:8001,127.0.0.1:2022-:22
        qemu+=( -nic user,model=virtio-net-pci${args[nat-fw]:+,hostfwd=tcp:${args[nat-fw]//,/,hostfwd=tcp:}} ) # NATed, IPs: 10.0.2.15+/32, gateway: 10.0.2.2
    fi

    # TODO: network bridging:
    #[[ @{config.networking.hostId} =~ ^(.)(.)(.)(.)(.)(.)(.)(.)$ ]] ; mac=$( printf "52:54:%s%s:%s%s:%s%s:%s%s" "${BASH_REMATCH[@]:1}" )
    #qemu+=( -netdev bridge,id=enp0s3,macaddr=$mac -device virtio-net-pci,netdev=hn0,id=nic1 )

    # To pass a USB device (e.g. a YubiKey for unlocking), add pass »--usb-port=${bus}-${port}«, where bus and port refer to the physical USB port »/sys/bus/usb/devices/${bus}-${port}« (see »lsusb -tvv«). E.g.: »--usb-port=3-1.1.1.4«
    if [[ ${args[usb-port]:-} ]] ; then local decl ; for decl in ${args[usb-port]//:/ } ; do
        qemu+=( -usb -device usb-host,hostbus="${decl/-*/}",hostport="${decl/*-/}" )
    done ; fi

    if [[ ${args[install]:-} == 1 ]] ; then local disk ; for disk in "${disks[@]}" ; do
        if [[ ! -e $disk ]] ; then args[install]=always ; fi
    done ; fi
    if [[ ${args[install]:-} == always ]] ; then
        local verbosity=--quiet ; if [[ ${args[trace]:-} ]] ; then verbosity=--trace ; fi ; if [[ ${args[debug]:-} ]] ; then verbosity=--debug ; fi
        hostPath=${hostPath:-} ${args[dry-run]:+echo} $0 install-system "$diskImages" $verbosity --no-inspect || return
    fi

    qemu+=( "${argv[@]}" )
    if [[ ${args[dry-run]:-} ]] ; then
        echo "${qemu[@]}"
    else
        ( set -x ; "${qemu[@]}" ) || return
    fi

    # https://askubuntu.com/questions/54814/how-can-i-ctrl-alt-f-to-get-to-a-tty-in-a-qemu-session
}

## Creates a random static key on a new key partition on the GPT partitioned »$blockDev«. The drive can then be used as headless but removable disk unlock method.
#  To create/clear the GPT: $ sgdisk --zap-all "$blockDev"
function add-bootkey-to-keydev { # 1: blockDev, 2?: hostHash
    local blockDev=$1 ; local hostHash=${2:-@{config.networking.hostName!hashString.sha256}}
    local bootkeyPartlabel=bootkey-${hostHash:0:8}
    @{native.gptfdisk}/bin/sgdisk --new=0:0:+1 --change-name=0:"$bootkeyPartlabel" --typecode=0:0000 "$blockDev" || exit # create new 1 sector (512b) partition
    @{native.parted}/bin/partprobe "$blockDev" && @{native.systemd}/bin/udevadm settle -t 15 || exit # wait for partitions to update
    </dev/urandom tr -dc 0-9a-f | head -c 512 >/dev/disk/by-partlabel/"$bootkeyPartlabel" || exit
}

## Tries to open and mount the systems keystore from its LUKS partition. If successful, adds the traps to close it when the parent shell exits.
#  For the exit traps to trigger on exit from the calling script / shell, this can't run in a sub shell (and therefore can't be called from a pipeline).
#  See »open-system«'s implementation for some example calls to this function.
function mount-keystore-luks { # ...: cryptsetupOptions
    local keystore=keystore-@{config.networking.hostName!hashString.sha256:0:8}
    mkdir -p -- /run/$keystore && prepend_trap "[[ ! -e /run/$keystore ]] || rmdir /run/$keystore" EXIT || return
    @{native.cryptsetup}/bin/cryptsetup open "$@" /dev/disk/by-partlabel/$keystore $keystore && prepend_trap "@{native.cryptsetup}/bin/cryptsetup close $keystore" EXIT || return
    @{native.util-linux}/bin/mount -o nodev,umask=0077,fmask=0077,dmask=0077,ro /dev/mapper/$keystore /run/$keystore && prepend_trap "@{native.util-linux}/bin/umount /run/$keystore" EXIT || return
}

## Performs any steps necessary to mount the target system at »/tmp/nixos-install-@{config.networking.hostName}« on the current host.
#  For any steps taken, it also adds the steps to undo them on exit from the calling shell (so don't call this from a sub-shell that exits too early).
#  »diskImages« may be passed in the same format as to the installer. If so, any image files are ensured to be loop-mounted.
#  Perfect to inspect/update/amend/repair a system's installation afterwards, e.g.:
#  $ source ${config_wip_fs_disks_initSystemCommands1writeText_initSystemCommands}
#  $ source ${config_wip_fs_disks_restoreSystemCommands1writeText_restoreSystemCommands}
#  $ install-system-to $mnt
#  $ nixos-install --system ${config_system_build_toplevel} --no-root-passwd --no-channel-copy --root $mnt
#  $ nixos-enter --root $mnt
function open-system { # 1?: diskImages
    local diskImages=${1:-} # If »diskImages« were specified and they point at files that aren't loop-mounted yet, then loop-mount them now:
    local images=$( @{native.util-linux}/bin/losetup --list --all --raw --noheadings --output BACK-FILE )
    local decl ; for decl in ${diskImages//:/ } ; do
        local image=${decl/*=/} ; if [[ $image != /dev/* ]] && ! <<<$images grep -xF $image ; then
            local blockDev=$( @{native.util-linux}/bin/losetup --show -f "$image" ) && prepend_trap "@{native.util-linux}/bin/losetup -d '$blockDev'" EXIT || return
            @{native.parted}/bin/partprobe "$blockDev" || return
        fi
    done
    @{native.systemd}/bin/udevadm settle -t 15 || true # sometimes partitions aren't quite made available yet

    if [[ @{config.wip.fs.keystore.enable} && ! -e /dev/mapper/keystore-@{config.networking.hostName!hashString.sha256:0:8} ]] ; then # Try a bunch of approaches for opening the keystore:
        mount-keystore-luks --key-file=<( printf %s "@{config.networking.hostName}" ) || return
        mount-keystore-luks --key-file=/dev/disk/by-partlabel/bootkey-@{config.networking.hostName!hashString.sha256:0:8} || return
        mount-keystore-luks --key-file=<( read -s -p PIN: pin && echo ' touch!' >&2 && @{native.yubikey-personalization}/bin/ykchalresp -2 "$pin" ) || return
        # TODO: try static yubikey challenge
        mount-keystore-luks || return
    fi

    mnt=/tmp/nixos-install-@{config.networking.hostName} # allow this to leak into the calling scope
    if [[ ! -e $mnt ]] ; then mkdir -p "$mnt" && prepend_trap "rmdir '$mnt'" EXIT || return ; fi

    open-luks-layers || return # Load crypt layers and zfs pools:
    if [[ $( LC_ALL=C type -t ensure-datasets ) == 'function' ]] ; then
        local poolName ; for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
            if [[ ! @{config.wip.fs.zfs.pools!catAttrSets.createDuringInstallation[$poolName]} ]] ; then continue ; fi
            if ! @{native.zfs}/bin/zfs get -o value -H name "$poolName" &>/dev/null ; then
                @{native.zfs}/bin/zpool import -f -N -R "$mnt" "$poolName" && prepend_trap "@{native.zfs}/bin/zpool export '$poolName'" EXIT || return
            fi
            : | @{native.zfs}/bin/zfs load-key -r "$poolName" || true
            ensure-datasets "$mnt" '^'"$poolName"'($|[/])' || return
        done
    fi

    prepend_trap "unmount-system '$mnt'" EXIT && mount-system "$mnt" '' 1 || return
    df -h | grep $mnt | cat
}
