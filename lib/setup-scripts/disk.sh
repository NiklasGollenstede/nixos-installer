
##
# Disk Partitioning and Formatting
##

## Prepares the disks of the target system for the copying of files.
function do-disk-setup { # 1: diskPaths

    mnt=/tmp/nixos-install-@{config.networking.hostName} ; mkdir -p "$mnt" ; prepend_trap "rmdir $mnt" EXIT # »mnt=/run/user/0/...« would be more appropriate, but »nixos-install« does not like the »700« permissions on »/run/user/0«

    partition-disks "$1"
    # ... block layers would go here ...
    source @{config.wip.installer.postPartitionCommands!writeText.postPartitionCommands}
    format-partitions
    source @{config.wip.installer.postFormatCommands!writeText.postFormatCommands}
    prepend_trap "unmount-system $mnt" EXIT ; mount-system $mnt
    source @{config.wip.installer.postMountCommands!writeText.postMountCommands}

}

## Partitions all »config.installer.disks« to ensure that all (correctly) specified »{config.installer.partitions« exist.
function partition-disks { { # 1: diskPaths
    beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then beQuiet=/dev/stdout ; fi
    declare -g -A blockDevs=( ) # this ends up in the caller's scope
    local path ; for path in ${1/:/ } ; do
        name=${path/=*/} ; if [[ $name != "$path" ]] ; then path=${path/$name=/} ; else name=primary ; fi
        if [[ ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name specified more than once. Duplicate definition: $path" ; exit 1 ; fi
        blockDevs[$name]=$path
    done

    local name ; for name in "@{!config.wip.installer.disks!attrsAsBashEvalSets[@]}" ; do
        if [[ ! ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name not provided" ; exit 1 ; fi
        if [[ ! ${blockDevs[$name]} =~ ^(/dev/.*)$ ]] ; then
            local outFile=${blockDevs[$name]} ; ( set -eu
                eval "@{config.wip.installer.disks!attrsAsBashEvalSets[$name]}" # _size
                install -o root -g root -m 640 -T /dev/null "$outFile" && fallocate -l "$_size" "$outFile"
            ) && blockDevs[$name]=$(losetup --show -f "$outFile") && prepend_trap "losetup -d ${blockDevs[$name]}" EXIT # NOTE: this must not be inside a sub-shell!
        else
            if [[ ! "$(blockdev --getsize64 "${blockDevs[$name]}")" ]] ; then echo "Block device $name does not exist at ${blockDevs[$name]}" ; exit 1 ; fi
            blockDevs[$name]=$(realpath "${blockDevs[$name]}")
        fi
    done

} ; ( set -eu

    for name in "@{!config.wip.installer.disks!attrsAsBashEvalSets[@]}" ; do (
        eval "@{config.wip.installer.disks!attrsAsBashEvalSets[$name]}" # _name ; _size ; _serial ; _alignment ; _mbrParts ; _extraFDiskCommands
        if [[ $_serial ]] ; then
            actual=$(udevadm info --query=property --name="${blockDevs[$name]}" | grep -oP 'ID_SERIAL_SHORT=\K.*')
            if [[ $_serial != "$actual" ]] ; then echo "Block device ${blockDevs[$name]} does not match the serial declared for $name" ; exit 1 ; fi
        fi

        sgdisk=( --zap-all ) # delete existing part tables
        for partDecl in "@{config.wip.installer.partitionList!listAsBashEvalSets[@]}" ; do
            eval "$partDecl" # _name ; _disk ; _type ; _size ; _index
            if [[ $_disk != "$name" ]] ; then exit ; fi # i.e. continue
            if [[ $_position =~ ^[0-9]+$ ]] ; then alignment=1 ; else alignment=$_alignment ; fi # if position is an absolute number, start precisely there
            sgdisk+=( -a "$alignment" -n "${_index:-0}":"$_position":+"$_size" -t 0:"$_type" -c 0:"$_name" )
        done

        if [[ $_mbrParts ]] ; then
            sgdisk+=( --hybrid "$_mbrParts" ) # --hybrid: create MBR in addition to GPT; $_mbrParts: make these GPT part 1 MBR parts 2[3[4]]
        fi

        sgdisk "${sgdisk[@]}" "${blockDevs[$name]}" >$beQuiet # running all at once is much faster

        if [[ $_mbrParts ]] ; then
            printf "
                M                                # edit hybrid MBR
                d;1                              # delete parts 1 (GPT)

                # move the selected »mbrParts« to slots 1[2[3]] instead of 2[3[4]] (by re-creating part1 in the last sector, then sorting)
                n;p;1                            # new ; primary ; part1
                $(( $(blockSectorCount "${blockDevs[$name]}") - 1)) # start (size 1sec)
                x;f;r                            # expert mode ; fix order ; return
                d;$(( (${#_mbrParts} + 1) / 2 + 1 )) # delete ; part(last)

                # create GPT part (spanning primary GPT area) as last part
                n;p;4                            # new ; primary ; part4
                1;33                             # start ; end
                t;4;ee                           # type ; part4 ; GPT

                ${_extraFDiskCommands}
                p;w;q                            # print ; write ; quit
            " | perl -pe 's/^ *| *(#.*)?$//g' | perl -pe 's/\n\n+| *; */\n/g' | fdisk "${blockDevs[$name]}" &>$beQuiet
        fi

        partprobe "${blockDevs[$name]}"
    ) ; done
    sleep 1 # sometimes partitions aren't quite made available yet (TODO: wait "for udev to settle" instead?)
)}

## For each filesystem in »config.fileSystems« whose ».device« is in »/dev/disk/by-partlabel/«, this creates the specified file system on that partition.
function format-partitions {( set -eu
    beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then beQuiet=/dev/stdout ; fi
    for fsDecl in "@{config.fileSystems!attrsAsBashEvalSets[@]}" ; do (
        eval "$fsDecl" # _name ; _device ; _fsType ; _formatOptions ; ...
        if [[ $_device != /dev/disk/by-partlabel/* ]] ; then exit ; fi # i.e. continue
        blockDev=$(realpath "$_device") ;  if [[ $blockDev == /dev/sd* ]] ; then
            blockDev=$( shopt -s extglob ; echo "${blockDev%%+([0-9])}" )
        else
            blockDev=$( shopt -s extglob ; echo "${blockDev%%p+([0-9])}" )
        fi
        if [[ ' '"${blockDevs[@]}"' ' != *' '"$blockDev"' '* ]] ; then echo "Partition alias $_device does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        mkfs.${_fsType} ${_formatOptions} "${_device}" >$beQuiet
        partprobe "${_device}"
    ) ; done
)}

## Mounts all file systems as it would happen during boot, but at path prefix »$mnt«.
function mount-system {( set -eu # 1: mnt, 2?: fstabPath
    # mount --all --fstab @{config.system.build.toplevel.outPath}/etc/fstab --target-prefix "$1" -o X-mount.mkdir # (»--target-prefix« is not supported on Ubuntu 20.04)
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel.outPath}/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] || [[ $type == overlay ]] ; then continue ; fi
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkdir -p "$mnt"/"$target"
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
    # Since bind mounts may depend on other mounts not only for the target (which the sort takes care of) but also for the source, do all bind mounts last. This would break if there was a different bind mountpoint within a bind-mounted target.
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] || [[ $type == overlay ]] ; then : ; else continue ; fi
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkdir -p "$mnt"/"$target"
            if [[ $type == overlay ]] ; then
                options=${options//,workdir=/,workdir=$mnt\/} ; options=${options//,upperdir=/,upperdir=$mnt\/} # work and upper dirs must be in target, lower dirs are probably store paths
                workdir=$(<<<"$options" grep -o -P ',workdir=\K[^,]+' || true) ; if [[ $workdir ]] ; then mkdir -p "$workdir" ; fi
                upperdir=$(<<<"$options" grep -o -P ',upperdir=\K[^,]+' || true) ; if [[ $upperdir ]] ; then mkdir -p "$upperdir" ; fi
            else
                source=$mnt/$source ; if [[ ! -e $source ]] ; then mkdir -p "$source" ; fi
            fi
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
)}

## Unmounts all file systems (that would be mounted during boot / by »mount-system«).
function unmount-system {( set -eu # 1: mnt, 2?: fstabPath
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel.outPath}/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 -r | while read source target rest ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        if mountpoint -q "$mnt"/"$target" ; then
            umount "$mnt"/"$target"
        fi
    done
)}

## Given a block device path, returns the number of 512byte sectors it can hold.
function blockSectorCount { printf %s "$(( $(blockdev --getsize64 "$1") / 512 ))" ; }
