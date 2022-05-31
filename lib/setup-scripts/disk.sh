
##
# Disk Partitioning and Formatting
##

## Prepares the disks of the target system for the copying of files.
function do-disk-setup { # 1: diskPaths

    prompt-for-user-passwords &&
    populate-keystore &&

    mnt=/tmp/nixos-install-@{config.networking.hostName} && mkdir -p "$mnt" && prepend_trap "rmdir $mnt" EXIT && # »mnt=/run/user/0/...« would be more appropriate, but »nixos-install« does not like the »700« permissions on »/run/user/0«

    partition-disks "$1" &&
    create-luks-layers && open-luks-layers && # other block layers would go here too (but figuring out their dependencies would be difficult)
    run-hook-script 'Post Partitioning' @{config.wip.fs.disks.postPartitionCommands!writeText.postPartitionCommands} &&

    format-partitions &&
    { [[ $(LC_ALL=C type -t create-zpools) != function ]] || create-zpools $mnt ; } &&
    run-hook-script 'Post Formatting' @{config.wip.fs.disks.postFormatCommands!writeText.postFormatCommands} &&

    prepend_trap "unmount-system $mnt" EXIT && mount-system $mnt &&
    run-hook-script 'Post Mounting' @{config.wip.fs.disks.postMountCommands!writeText.postMountCommands} &&
    :
}

# Notes segmentation and alignment:
# * Both fdisk and gdisk report start and end in 0-indexed sectors from the start of the block device.
# * (fdisk and gdisk have slightly different interfaces, but seem to otherwise be mostly equivalent, (fdisk used to not understand GPT).)
# * The MBR sits only in the first sector, a GPT additionally requires next 33 (34 total) and the (absolute) last 33 sectors. At least fdisk won't put partitions in the first 2048 sectors on MBRs.
# * Crappy flash storage (esp. micro SD cards) requires alignment to pretty big sectors for optimal (esp. write) performance. For reasons of inconvenience, vendors don't document the size of those. Not too extensive test with 4 (in 2022 considered to be among the more decent) micro SD cards indicates the magic number to be somewhere between 1 and 4MiB, but it may very well be higher for others.
#     * (source: https://lwn.net/Articles/428584/)
# * So alignment at the default »align=8MiB« actually seems a decent choice.


## Partitions all »config.wip.fs.disks.devices« to ensure that all (correctly) specified »config.wip.fs.disks.partitions« exist.
function partition-disks { { # 1: diskPaths
    beQuiet=/dev/null ; if [[ ${args[debug]:-} ]] ; then beQuiet=/dev/stdout ; fi
    declare -g -A blockDevs=( ) # this ends up in the caller's scope
    local path ; for path in ${1//:/ } ; do
        local name=${path/=*/} ; if [[ $name != "$path" ]] ; then path=${path/$name=/} ; else name=primary ; fi
        if [[ ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name specified more than once. Duplicate definition: $path" ; exit 1 ; fi
        blockDevs[$name]=$path
    done

    local name ; for name in "@{!config.wip.fs.disks.devices[@]}" ; do
        if [[ ! ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name not provided" ; exit 1 ; fi
        if [[ ! ${blockDevs[$name]} =~ ^(/dev/.*)$ ]] ; then
            local outFile=${blockDevs[$name]} ; ( set -eu
                eval 'declare -A disk='"@{config.wip.fs.disks.devices[$name]}"
                install -o root -g root -m 640 -T /dev/null "$outFile" && fallocate -l "${disk[size]}" "$outFile"
            ) && blockDevs[$name]=$(losetup --show -f "$outFile") && prepend_trap "losetup -d ${blockDevs[$name]}" EXIT # NOTE: this must not be inside a sub-shell!
        else
            if [[ ! "$(blockdev --getsize64 "${blockDevs[$name]}")" ]] ; then echo "Block device $name does not exist at ${blockDevs[$name]}" ; exit 1 ; fi
            blockDevs[$name]=$(realpath "${blockDevs[$name]}")
        fi
    done

} && ( set -eu

    for partDecl in "@{config.wip.fs.disks.partitionList[@]}" ; do
        eval 'declare -A part='"$partDecl"
        if [[ -e /dev/disk/by-partlabel/"${part[name]}" ]] && ! is-partition-on-disks /dev/disk/by-partlabel/"${part[name]}" "${blockDevs[@]}" ; then echo "Partition /dev/disk/by-partlabel/${part[name]} exists but does not reside on one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
    done

    for name in "@{!config.wip.fs.disks.devices[@]}" ; do (
        eval 'declare -A disk='"@{config.wip.fs.disks.devices[$name]}"
        if [[ ${disk[serial]:-} ]] ; then
            actual=$(udevadm info --query=property --name="${blockDevs[${disk[name]}]}" | @{native.gnugrep}/bin/grep -oP 'ID_SERIAL_SHORT=\K.*')
            if [[ ${disk[serial]} != "$actual" ]] ; then echo "Block device ${blockDevs[${disk[name]}]} does not match the serial declared for ${disk[name]}" ; exit 1 ; fi
        fi

        declare -a sgdisk=( --zap-all ) # delete existing part tables
        for partDecl in "@{config.wip.fs.disks.partitionList[@]}" ; do
            eval 'declare -A part='"$partDecl"
            if [[ ${part[disk]} != "${disk[name]}" ]] ; then continue ; fi
            if [[ ${part[size]:-} =~ ^[0-9]+%$ ]] ; then
                devSize=$(blockdev --getsize64 "${blockDevs[${disk[name]}]}")
                part[size]=$(( $devSize / 1024 * ${part[size]:0:(-1)} / 100 ))K
            fi
            sgdisk+=( -a "${part[alignment]:-${disk[alignment]}}" -n "${part[index]:-0}":"${part[position]}":+"${part[size]:-}" -t 0:"${part[type]}" -c 0:"${part[name]}" )
        done

        if [[ ${disk[mbrParts]:-} ]] ; then
            sgdisk+=( --hybrid "${disk[mbrParts]}" ) # --hybrid: create MBR in addition to GPT; ${disk[mbrParts]}: make these GPT part 1 MBR parts 2[3[4]]
        fi

        ( PATH=@{native.gptfdisk}/bin ; set -x ; sgdisk "${sgdisk[@]}" "${blockDevs[${disk[name]}]}" >$beQuiet ) # running all at once is much faster

        if [[ ${disk[mbrParts]:-} ]] ; then
            printf "
                M                                # edit hybrid MBR
                d;1                              # delete parts 1 (GPT)

                # move the selected »mbrParts« to slots 1[2[3]] instead of 2[3[4]] (by re-creating part1 in the last sector, then sorting)
                n;p;1                            # new ; primary ; part1
                $(( $(blockSectorCount "${blockDevs[${disk[name]}]}") - 1)) # start (size 1sec)
                x;f;r                            # expert mode ; fix order ; return
                d;$(( (${#disk[mbrParts]} + 1) / 2 + 1 )) # delete ; part(last)

                # create GPT part (spanning primary GPT area) as last part
                n;p;4                            # new ; primary ; part4
                1;33                             # start ; end
                t;4;ee                           # type ; part4 ; GPT

                ${disk[extraFDiskCommands]}
                p;w;q                            # print ; write ; quit
            " | @{native.gnused}/bin/sed -E 's/^ *| *(#.*)?$//g' | @{native.gnused}/bin/sed -E 's/\n\n+| *; */\n/g' | tee >((echo -n '++ ' ; tr $'\n' '|' ; echo) 1>&2) | ( set -x ; fdisk "${blockDevs[${disk[name]}]}" &>$beQuiet )
        fi

    ) ; done
    @{native.parted}/bin/partprobe "${blockDevs[@]}"
    @{native.systemd}/bin/udevadm settle -t 15 || true # sometimes partitions aren't quite made available yet

    # ensure that filesystem creation does not complain about the devices already being occupied by a previous filesystem
    wipefs --all "@{config.wip.fs.disks.partitions!attrNames[@]/#/'/dev/disk/by-partlabel/'}" >$beQuiet
)}

## Checks whether a »partition« resides on one of the provided »blockDevs«.
function is-partition-on-disks {( set -eu # 1: partition, ...: blockDevs
    partition=$1 ; shift ; declare -a blockDevs=( "$@" )
    blockDev=$(realpath "$partition") ; if [[ $blockDev == /dev/sd* ]] ; then
        blockDev=$( shopt -s extglob ; echo "${blockDev%%+([0-9])}" )
    else
        blockDev=$( shopt -s extglob ; echo "${blockDev%%p+([0-9])}" )
    fi
    [[ ' '"${blockDevs[@]}"' ' == *' '"$blockDev"' '* ]]
)}

## For each filesystem in »config.fileSystems« whose ».device« is in »/dev/disk/by-partlabel/«, this creates the specified file system on that partition.
function format-partitions {( set -eu
    beQuiet=/dev/null ; if [[ ${args[debug]:-} ]] ; then beQuiet=/dev/stdout ; fi
    for fsDecl in "@{config.fileSystems[@]}" ; do
        eval 'declare -A fs='"$fsDecl"
        if [[ ${fs[device]} == /dev/disk/by-partlabel/* ]] ; then
            if ! is-partition-on-disks "${fs[device]}" "${blockDevs[@]}" ; then echo "Partition alias ${fs[device]} used by mount ${fs[mountPoint]} does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        elif [[ ${fs[device]} == /dev/mapper/* ]] ; then
            if [[ ! @{config.boot.initrd.luks.devices!catAttrSets.device[${fs[device]/'/dev/mapper/'/}]:-} ]] ; then echo "LUKS device ${fs[device]} used by mount ${fs[mountPoint]} does not point at one of the device mappings ${!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; exit 1 ; fi
        else continue ; fi
        ( PATH=@{native.e2fsprogs}/bin:@{native.f2fs-tools}/bin:@{native.xfsprogs}/bin:@{native.dosfstools}/bin:$PATH ; set -x ; mkfs.${fs[fsType]} ${fs[formatOptions]} "${fs[device]}" >$beQuiet )
        @{native.parted}/bin/partprobe "${fs[device]}" || true
    done
    for swapDev in "@{config.swapDevices!catAttrs.device[@]}" ; do
        if [[ $swapDev == /dev/disk/by-partlabel/* ]] ; then
            if ! is-partition-on-disks "$swapDev" "${blockDevs[@]}" ; then echo "Partition alias $swapDev used for SWAP does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        elif [[ $swapDev == /dev/mapper/* ]] ; then
            if [[ ! @{config.boot.initrd.luks.devices!catAttrSets.device[${swapDev/'/dev/mapper/'/}]:-} ]] ; then echo "LUKS device $swapDev used for SWAP does not point at one of the device mappings @{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; exit 1 ; fi
        else continue ; fi
        ( set -x ; mkswap "$swapDev" >$beQuiet )
    done
)}

## Mounts all file systems as it would happen during boot, but at path prefix »$mnt« (instead of »/«).
function mount-system {( set -eu # 1: mnt, 2?: fstabPath
    # mount --all --fstab @{config.system.build.toplevel}/etc/fstab --target-prefix "$1" -o X-mount.mkdir # (»--target-prefix« is not supported on Ubuntu 20.04)
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel}/etc/fstab"}
    PATH=@{native.e2fsprogs}/bin:@{native.f2fs-tools}/bin:@{native.xfsprogs}/bin:@{native.dosfstools}/bin:$PATH
    <$fstabPath @{native.gnugrep}/bin/grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] || [[ $type == overlay ]] ; then continue ; fi
        if ! mountpoint -q "$mnt"/"$target" ; then (
            mkdir -p "$mnt"/"$target"
            [[ $type == tmpfs ]] || @{native.kmod}/bin/modprobe --quiet $type || true # (this does help sometimes)
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        ) || [[ $options == *,nofail,* ]] ; fi # (actually, nofail already makes mount fail silently)
    done
    # Since bind mounts may depend on other mounts not only for the target (which the sort takes care of) but also for the source, do all bind mounts last. This would break if there was a different bind mountpoint within a bind-mounted target.
    <$fstabPath @{native.gnugrep}/bin/grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] || [[ $type == overlay ]] ; then : ; else continue ; fi
        if ! mountpoint -q "$mnt"/"$target" ; then (
            mkdir -p "$mnt"/"$target"
            if [[ $type == overlay ]] ; then
                options=${options//,workdir=/,workdir=$mnt\/} ; options=${options//,upperdir=/,upperdir=$mnt\/} # work and upper dirs must be in target, lower dirs are probably store paths
                workdir=$(<<<"$options" @{native.gnugrep}/bin/grep -o -P ',workdir=\K[^,]+' || true) ; if [[ $workdir ]] ; then mkdir -p "$workdir" ; fi
                upperdir=$(<<<"$options" @{native.gnugrep}/bin/grep -o -P ',upperdir=\K[^,]+' || true) ; if [[ $upperdir ]] ; then mkdir -p "$upperdir" ; fi
            else
                source=$mnt/$source ; if [[ ! -e $source ]] ; then mkdir -p "$source" ; fi
            fi
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        ) || [[ $options == *,nofail,* ]] ; fi
    done
)}

## Unmounts all file systems (that would be mounted during boot / by »mount-system«).
function unmount-system {( set -eu # 1: mnt, 2?: fstabPath
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel}/etc/fstab"}
    <$fstabPath @{native.gnugrep}/bin/grep -v '^#' | LC_ALL=C sort -k2 -r | while read source target rest ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        if mountpoint -q "$mnt"/"$target" ; then
            umount "$mnt"/"$target"
        fi
    done
)}

## Given a block device path, returns the number of 512byte sectors it can hold.
function blockSectorCount { printf %s "$(( $(blockdev --getsize64 "$1") / 512 ))" ; }
