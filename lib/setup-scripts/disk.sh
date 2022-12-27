
##
# Disk Partitioning and Formatting
##

## Prepares the disks of the target system for the copying of files.
function do-disk-setup { # 1: diskPaths

    prompt-for-user-passwords || return
    populate-keystore || return

    mnt=/tmp/nixos-install-@{config.networking.hostName} && mkdir -p "$mnt" && prepend_trap "rmdir $mnt" EXIT || return # »mnt=/run/user/0/...« would be more appropriate, but »nixos-install« does not like the »700« permissions on »/run/user/0«

    partition-disks "$1" || return
    create-luks-layers && open-luks-layers || return # other block layers would go here too (but figuring out their dependencies would be difficult)
    run-hook-script 'Post Partitioning' @{config.wip.fs.disks.postPartitionCommands!writeText.postPartitionCommands} || return

    format-partitions || return
    if [[ $(LC_ALL=C type -t create-zpools) == function ]] ; then create-zpools $mnt || return ; fi
    run-hook-script 'Post Formatting' @{config.wip.fs.disks.postFormatCommands!writeText.postFormatCommands} || return

    fix-grub-install || return

    prepend_trap "unmount-system $mnt" EXIT && mount-system $mnt || return
    run-hook-script 'Post Mounting' @{config.wip.fs.disks.postMountCommands!writeText.postMountCommands} || return
}

# Notes on segmentation and alignment:
# * Both fdisk and gdisk report start and end in 0-indexed sectors from the start of the block device.
# * (fdisk and gdisk have slightly different interfaces, but seem to otherwise be mostly equivalent, (fdisk used to not understand GPT).)
# * The MBR sits only in the first sector, a GPT additionally requires next 33 (34 total) and the (absolute) last 33 sectors. At least fdisk won't put partitions in the first 2048 sectors on MBRs.
# * Crappy flash storage (esp. micro SD cards) requires alignment to pretty big sectors for optimal (esp. write) performance. For reasons of inconvenience, vendors don't document the size of those. Not too extensive test with 4 (in 2022 considered to be among the more decent) micro SD cards indicates the magic number to be somewhere between 1 and 4MiB, but it may very well be higher for others.
#     * (source: https://lwn.net/Articles/428584/)
# * So alignment at the default »align=8MiB« actually seems a decent choice.


## Partitions the »diskPaths« instances of all »config.wip.fs.disks.devices« to ensure that all specified »config.wip.fs.disks.partitions« exist.
#  Parses »diskPaths«, creates and loop-mounts images for non-/dev/ paths, and tries to abort if any partition already exists on the host.
function partition-disks { # 1: diskPaths
    local beLoud=/dev/null ; if [[ ${args[debug]:-} ]] ; then beLoud=/dev/stdout ; fi
    local beSilent=/dev/stderr ; if [[ ${args[quiet]:-} ]] ; then beSilent=/dev/null ; fi
    declare -g -A blockDevs=( ) # this ends up in the caller's scope
    local path ; for path in ${1//:/ } ; do
        local name=${path/=*/} ; if [[ $name != "$path" ]] ; then path=${path/$name=/} ; else name=primary ; fi
        if [[ ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name specified more than once. Duplicate definition: $path" 1>&2 ; return 1 ; fi
        blockDevs[$name]=$path
    done

    local name ; for name in "@{!config.wip.fs.disks.devices[@]}" ; do
        if [[ ! ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name not provided" 1>&2 ; return 1 ; fi
        eval 'local -A disk='"@{config.wip.fs.disks.devices[$name]}"
        if [[ ${blockDevs[$name]} != /dev/* ]] ; then
            local outFile=${blockDevs[$name]} &&
            install -o root -g root -m 640 -T /dev/null "$outFile" && truncate -s "${disk[size]}" "$outFile" &&
            blockDevs[$name]=$( losetup --show -f "$outFile" ) && prepend_trap "losetup -d '${blockDevs[$name]}'" EXIT # NOTE: this must not be inside a sub-shell!
        else
            local size=$( blockdev --getsize64 "${blockDevs[$name]}" || : ) ; local waste=$(( size - ${disk[size]} ))
            if [[ ! $size ]] ; then echo "Block device $name does not exist at ${blockDevs[$name]}" 1>&2 ; return 1 ; fi
            if (( waste < 0 )) ; then echo "Block device ${blockDevs[$name]}'s size $size is smaller than the size ${disk[size]} declared for $name" ; return 1 ; fi
            if (( waste > 0 )) && [[ ! ${disk[allowLarger]:-} ]] ; then echo "Block device ${blockDevs[$name]}'s size $size is bigger than the size ${disk[size]} declared for $name" 1>&2 ; return 1 ; fi
            if (( waste > 0 )) ; then echo "Wasting $(( waste / 1024))K of ${blockDevs[$name]} due to the size declared for $name (should be ${size}b)" 1>&2 ; fi
            blockDevs[$name]=$(realpath "${blockDevs[$name]}")
        fi
    done

    for partDecl in "@{config.wip.fs.disks.partitionList[@]}" ; do
        eval 'local -A part='"$partDecl"
        if [[ -e /dev/disk/by-partlabel/"${part[name]}" ]] && ! is-partition-on-disks /dev/disk/by-partlabel/"${part[name]}" "${blockDevs[@]}" ; then echo "Partition /dev/disk/by-partlabel/${part[name]} already exists on this host and does not reside on one of the target disks ${blockDevs[@]}. Refusing to create another partition with the same partlabel!" 1>&2 ; return 1 ; fi
    done

    for name in "@{!config.wip.fs.disks.devices[@]}" ; do
        eval 'local -A disk='"@{config.wip.fs.disks.devices[$name]}"
        if [[ ${disk[serial]:-} ]] ; then
            actual=$( udevadm info --query=property --name="$blockDev" | grep -oP 'ID_SERIAL_SHORT=\K.*' || echo '<none>' )
            if [[ ${disk[serial]} != "$actual" ]] ; then echo "Block device $blockDev's serial ($actual) does not match the serial (${disk[serial]}) declared for ${disk[name]}" 1>&2 ; return 1 ; fi
        fi
        # can (and probably should) restore the backup:
        ( PATH=@{native.gptfdisk}/bin ; ${_set_x:-:} ; sgdisk --zap-all --load-backup=@{config.wip.fs.disks.partitioning}/"${disk[name]}".backup ${disk[allowLarger]:+--move-second-header} "${blockDevs[${disk[name]}]}" >$beLoud 2>$beSilent || exit ) || return
        #partition-disk "${disk[name]}" "${blockDevs[${disk[name]}]}"
    done
    @{native.parted}/bin/partprobe "${blockDevs[@]}" &>$beLoud || return
    @{native.systemd}/bin/udevadm settle -t 15 || true # sometimes partitions aren't quite made available yet

    # ensure that filesystem creation does not complain about the devices already being occupied by a previous filesystem
    wipefs --all "@{config.wip.fs.disks.partitions!attrNames[@]/#/'/dev/disk/by-partlabel/'}" >$beLoud 2>$beSilent || return
    #</dev/zero head -c 4096 | tee "@{config.wip.fs.disks.partitions!attrNames[@]/#/'/dev/disk/by-partlabel/'}" >/dev/null
    #for part in "@{config.wip.fs.disks.partitions!attrNames[@]/#/'/dev/disk/by-partlabel/'}" ; do @{native.util-linux}/bin/blkdiscard -f "$part" || return ; done
}

## Given a declared disk device's »name« and a path to an actual »blockDev« (or image) file, partitions the device as declared in the config.
function partition-disk { # 1: name, 2: blockDev, 3?: devSize
    local name=$1 ; local blockDev=$2
    local beLoud=/dev/null ; if [[ ${args[debug]:-} ]] ; then beLoud=/dev/stdout ; fi
    local beSilent=/dev/stderr ; if [[ ${args[quiet]:-} ]] ; then beSilent=/dev/null ; fi
    eval 'local -A disk='"@{config.wip.fs.disks.devices[$name]}"
    local devSize=${3:-$( @{native.util-linux}/bin/blockdev --getsize64 "$blockDev" )}

    local -a sgdisk=( --zap-all ) # delete existing part tables
    if [[ ${disk[gptOffset]} != 0 ]] ; then
        echo 'Setting »gptOffset != 0« is currently not supported, as sgdisk with the patch applied somehow fails to read files' 1>&2 ; return 1
        sgdisk+=( --move-main-table=$(( 2 + ${disk[gptOffset]} )) ) # this is incorrectly documented as --adjust-main-table in the man pages (at least versions 1.05 to 1.09 incl)
        sgdisk+=( --move-backup-table=$(( devSize/${disk[sectorSize]} - 1 - 32 - ${disk[gptOffset]} )) )
    fi
    sgdisk+=( --disk-guid="${disk[guid]}" )

    for partDecl in "@{config.wip.fs.disks.partitionList[@]}" ; do
        eval 'local -A part='"$partDecl"
        if [[ ${part[disk]} != "${disk[name]}" ]] ; then continue ; fi
        if [[ ${part[size]:-} =~ ^[0-9]+%$ ]] ; then
            part[size]=$(( $devSize / 1024 * ${part[size]:0:(-1)} / 100 ))K
        fi
        sgdisk+=(
            --set-alignment="${part[alignment]:-${disk[alignment]}}"
            --new="${part[index]:-0}":"${part[position]}":+"${part[size]:-}"
            --partition-guid=0:"${part[guid]}"
            --typecode=0:"${part[type]}"
            --change-name=0:"${part[name]}"
        )
    done

    if [[ ${disk[mbrParts]:-} ]] ; then
        sgdisk+=( --hybrid "${disk[mbrParts]}" ) # --hybrid: create MBR in addition to GPT; ${disk[mbrParts]}: make these GPT part 1 MBR parts 2[3[4]]
    fi

    ( PATH=@{native.gptfdisk}/bin ; ${_set_x:-:} ; sgdisk "${sgdisk[@]}" "$blockDev" >$ || exit ) || return # running all at once is much faster

    if [[ ${disk[mbrParts]:-} ]] ; then
        printf "
            M                                # edit hybrid MBR
            d;1                              # delete parts 1 (GPT)

            # move the selected »mbrParts« to slots 1[2[3]] instead of 2[3[4]] (by re-creating part1 in the last sector, then sorting)
            n;p;1                            # new ; primary ; part1
            $(( ($devSize/${disk[sectorSize]}) - 1)) # start (size 1sec)
            x;f;r                            # expert mode ; fix order ; return
            d;$(( (${#disk[mbrParts]} + 1) / 2 + 1 )) # delete ; part(last)

            # create GPT part (spanning primary GPT area and its padding) as last part
            n;p;4                            # new ; primary ; part4
            1;$(( 33 + ${disk[gptOffset]} )) # start ; end
            t;4;ee                           # type ; part4 ; GPT

            ${disk[extraFDiskCommands]}
            p;w;q                            # print ; write ; quit
        " | @{native.gnused}/bin/sed -E 's/^ *| *(#.*)?$//g' | @{native.gnused}/bin/sed -E 's/\n\n+| *; */\n/g' | tee >((echo -n '++ ' ; tr $'\n' '|' ; echo) 1>&2) | ( PATH=@{native.util-linux}/bin ; ${_set_x:-:} ; fdisk "$blockDev" &>$beLoud || exit ) || return
    fi
}

## Checks whether a »partition« resides on one of the provided »blockDevs«.
function is-partition-on-disks { # 1: partition, ...: blockDevs
    local partition=$1 ; shift ; local -a blockDevs=( "$@" )
    local blockDev=$(realpath "$partition") ; if [[ $blockDev == /dev/sd* ]] ; then
        blockDev=$( shopt -s extglob ; echo "${blockDev%%+([0-9])}" )
    else
        blockDev=$( shopt -s extglob ; echo "${blockDev%%p+([0-9])}" )
    fi
    [[ ' '"${blockDevs[@]}"' ' == *' '"$blockDev"' '* ]]
}

## For each filesystem in »config.fileSystems« whose ».device« is in »/dev/disk/by-partlabel/«, this creates the specified file system on that partition.
function format-partitions {( set -u
    beLoud=/dev/null ; if [[ ${args[debug]:-} ]] ; then beLoud=/dev/stdout ; fi
    beSilent=/dev/stderr ; if [[ ${args[quiet]:-} ]] ; then beSilent=/dev/null ; fi
    for fsDecl in "@{config.fileSystems[@]}" ; do
        eval 'declare -A fs='"$fsDecl"
        if [[ ${fs[device]} == /dev/disk/by-partlabel/* ]] ; then
            if ! is-partition-on-disks "${fs[device]}" "${blockDevs[@]}" ; then echo "Partition alias ${fs[device]} used by mount ${fs[mountPoint]} does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        elif [[ ${fs[device]} == /dev/mapper/* ]] ; then
            if [[ ! @{config.boot.initrd.luks.devices!catAttrSets.device[${fs[device]/'/dev/mapper/'/}]:-} ]] ; then echo "LUKS device ${fs[device]} used by mount ${fs[mountPoint]} does not point at one of the device mappings ${!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; exit 1 ; fi
        else continue ; fi
        #if [[ ${fs[fsType]} == ext4 && ' '${fs[formatOptions]}' ' != *' -F '* ]] ; then fs[formatOptions]+=' -F' ; fi
        #if [[ ${fs[fsType]} == f2fs && ' '${fs[formatOptions]}' ' != *' -f '* ]] ; then fs[formatOptions]+=' -f' ; fi
        ( PATH=@{native.e2fsprogs}/bin:@{native.f2fs-tools}/bin:@{native.xfsprogs}/bin:@{native.dosfstools}/bin:$PATH ; ${_set_x:-:} ; mkfs.${fs[fsType]} ${fs[formatOptions]} "${fs[device]}" >$beLoud 2>$beSilent ) || exit
        @{native.parted}/bin/partprobe "${fs[device]}" || true
    done
    for swapDev in "@{config.swapDevices!catAttrs.device[@]}" ; do
        if [[ $swapDev == /dev/disk/by-partlabel/* ]] ; then
            if ! is-partition-on-disks "$swapDev" "${blockDevs[@]}" ; then echo "Partition alias $swapDev used for SWAP does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        elif [[ $swapDev == /dev/mapper/* ]] ; then
            if [[ ! @{config.boot.initrd.luks.devices!catAttrSets.device[${swapDev/'/dev/mapper/'/}]:-} ]] ; then echo "LUKS device $swapDev used for SWAP does not point at one of the device mappings @{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; exit 1 ; fi
        else continue ; fi
        ( ${_set_x:-:} ; mkswap "$swapDev" >$beLoud 2>$beSilent ) || exit
    done
)}

## This makes the installation of grub to loop devices shut up, but booting still does not work (no partitions are found). I'm done with GRUB; EXTLINUX works.
#  (This needs to happen before mounting.)
function fix-grub-install {
    if [[ @{config.boot.loader.grub.enable:-} ]] ; then
        if [[ @{config.boot.loader.grub.devices!length:-} != 1 || @{config.boot.loader.grub.mirroredBoots!length:-} != 0 ]] ; then echo "Installation of grub as mirrors or to more than 1 device may not work" 1>&2 ; fi
        for mount in '/boot' '/boot/grub' ; do
            if [[ ! @{config.fileSystems[$mount]:-} ]] ; then continue ; fi
            device=$( eval 'declare -A fs='"@{config.fileSystems[$mount]}" ; echo "${fs[device]}" )
            label=${device/\/dev\/disk\/by-partlabel\//}
            if [[ $label == "$device" || $label == *' '* || ' '@{config.wip.fs.disks.partitions!attrNames[@]}' ' != *' '$label' '* ]] ; then echo "" 1>&2 ; return 1 ; fi
            bootLoop=$( losetup --show -f /dev/disk/by-partlabel/$label ) || return ; prepend_trap "losetup -d $bootLoop" EXIT
            ln -sfT ${bootLoop/\/dev/..\/..} /dev/disk/by-partlabel/$label || return
        done
        #umount $mnt/boot/grub || true ; umount $mnt/boot || true ; mount $mnt/boot || true ; mount $mnt/boot/grub || true
    fi
}


## Mounts all file systems as it would happen during boot, but at path prefix »$mnt« (instead of »/«).
function mount-system {( set -eu # 1: mnt, 2?: fstabPath, 3?: allowFail
    # While not generally required for fstab, nixos uses the dependency-sorted »config.system.build.fileSystems« list (instead of plain »builtins.attrValues config.fileSystems«) to generate »/etc/fstab« (provided »config.fileSystems.*.depends« is set correctly, e.g. for overlay mounts).
    # This function depends on the file at »fstabPath« to be sorted like that.

    # The following is roughly equivalent to: mount --all --fstab @{config.system.build.toplevel}/etc/fstab --target-prefix "$1" -o X-mount.mkdir # (but »--target-prefix« is not supported with older versions on »mount«, e.g. on Ubuntu 20.04 (but can't we use mount from nixpkgs?))
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel}/etc/fstab"} ; allowFail=${3:-}
    PATH=@{native.e2fsprogs}/bin:@{native.f2fs-tools}/bin:@{native.xfsprogs}/bin:@{native.dosfstools}/bin:$PATH

    <$fstabPath grep -v '^#' | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}

        if ! mountpoint -q "$mnt"/"$target" ; then (
            mkdir -p "$mnt"/"$target" || exit
            [[ $type == tmpfs || $type == */* ]] || @{native.kmod}/bin/modprobe --quiet $type || true # (this does help sometimes)

            if [[ $type == overlay ]] ; then
                options=${options//,workdir=/,workdir=$mnt\/} ; options=${options//,upperdir=/,upperdir=$mnt\/} # Work and upper dirs must be in target.
                workdir=$(  <<<"$options" grep -o -P ',workdir=\K[^,]+'  || true ) ; if [[ $workdir  ]] ; then mkdir -p "$workdir"  ; fi
                upperdir=$( <<<"$options" grep -o -P ',upperdir=\K[^,]+' || true ) ; if [[ $upperdir ]] ; then mkdir -p "$upperdir" ; fi
                lowerdir=$( <<<"$options" grep -o -P ',lowerdir=\K[^,]+' || true )
                options=${options//,lowerdir=$lowerdir,/,lowerdir=$mnt/${lowerdir//:/:$mnt\/},} ; source=overlay
                # TODO: test the lowerdir stuff
            elif [[ $options =~ ,r?bind, ]] ; then
                if [[ $source == /nix/store/* ]] ; then options=,ro$options ; fi
                source=$mnt/$source ; if [[ ! -e $source ]] ; then mkdir -p "$source" || exit ; fi
            fi

            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target" || exit

        ) || [[ $options == *,nofail,* || $allowFail ]] || exit ; fi # (actually, nofail already makes mount fail silently)
    done || exit
)}

## Unmounts all file systems (that would be mounted during boot / by »mount-system«).
function unmount-system {( set -eu # 1: mnt, 2?: fstabPath
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel}/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 -r | while read source target rest ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        if mountpoint -q "$mnt"/"$target" ; then
            umount "$mnt"/"$target"
        fi
    done
)}
