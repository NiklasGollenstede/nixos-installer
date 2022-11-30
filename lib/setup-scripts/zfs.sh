
## Creates all of the system's ZFS pools that are »createDuringInstallation«, plus their datasets.
function create-zpools { # 1: mnt
    local poolName ; for poolName in "@{!config.wip.fs.zfs.pools[@]}" ; do
        if [[ ! @{config.wip.fs.zfs.pools!catAttrSets.createDuringInstallation[$poolName]} ]] ; then continue ; fi
        create-zpool "$1" "$poolName"
    done
}

## Creates a single of the system's ZFS pools and its datasets.
function create-zpool { # 1: mnt, 2: poolName
    local mnt=$1 ; local poolName=$2 ; ( set -u
        eval 'declare -A pool='"@{config.wip.fs.zfs.pools[$poolName]}"
        eval 'declare -a vdevs='"${pool[vdevArgs]}"
        eval 'declare -A poolProps='"${pool[props]}"
        eval 'declare -A dataset='"@{config.wip.fs.zfs.datasets[${pool[name]}]}"
        eval 'declare -A dataProps='"${dataset[props]}"
        get-zfs-crypt-props "${dataset[name]}" dataProps
        declare -a args=( ) ; keySrc=/dev/null
        if [[ ${dataProps[keyformat]:-} == ephemeral ]] ; then
            dataProps[encryption]=aes-256-gcm ; dataProps[keyformat]=hex ; dataProps[keylocation]=file:///dev/stdin ; keySrc=/dev/urandom
        fi
        for name in "${!poolProps[@]}" ; do args+=( -o "${name}=${poolProps[$name]}" ) ; done
        for name in "${!dataProps[@]}" ; do args+=( -O "${name}=${dataProps[$name]}" ) ; done
        for index in "${!vdevs[@]}" ; do
            part=${vdevs[$index]} ; if [[ $part =~ ^(mirror|raidz[123]?|draid[123]?.*|spare|log|dedup|special|cache)$ ]] ; then continue ; fi
            if [[ @{config.boot.initrd.luks.devices!catAttrSets.device[$part]:-} ]] ; then
                vdevs[$index]=/dev/mapper/$part
            else
                part=/dev/disk/by-partlabel/$part ; vdevs[$index]=$part
                if ! is-partition-on-disks "$part" "${blockDevs[@]}" ; then echo "Partition alias $part used by zpool ${pool[name]} does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
            fi
        done
        <$keySrc tr -dc 0-9a-f | head -c 64 | ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zpool create "${args[@]}" -R "$mnt" "${pool[name]}" "${vdevs[@]}" || exit ) || exit
        @{native.zfs}/bin/zfs unload-key "$poolName" &>/dev/null || true
    ) || return
    prepend_trap "@{native.zfs}/bin/zpool export '$poolName'" EXIT || return
    ensure-datasets $mnt '^'"$poolName"'($|[/])' || return
}

## Ensures that the system's datasets exist and have the defined properties (but not that they don't have properties that aren't defined).
#  The pool(s) must exist, be imported with root prefix »$mnt«, and (if datasets are to be created or encryption roots to be inherited) the system's keystore must be open (see »mount-keystore-luks«) or the keys be loaded.
#  »keystatus« and »mounted« of existing datasets should remain unchanged, newly crated datasets will not be mounted but have their keys loaded.
function ensure-datasets {( set -eu # 1: mnt, 2?: filterExp
    if (( @{#config.wip.fs.zfs.datasets[@]} == 0 )) ; then return ; fi
    mnt=$1 ; while [[ "$mnt" == */ ]] ; do mnt=${mnt:0:(-1)} ; done # (remove any tailing slashes)
    filterExp=${2:-'^'}
    tmpMnt=$(mktemp -d) ; trap "rmdir $tmpMnt" EXIT
    zfs=@{native.zfs}/bin/zfs

    : 'Step-through is very verbose and breaks the loop, disabling it for this function' ; trap - debug
    printf '%s\0' "@{!config.wip.fs.zfs.datasets[@]}" | LC_ALL=C sort -z | while IFS= read -r -d $'\0' name ; do
        if  [[ ! $name =~ $filterExp ]] ; then printf 'Skipping dataset »%s« since it does not match »%s«\n' "$name" "$filterExp" >&2 ; continue ; fi

        eval 'declare -A dataset='"@{config.wip.fs.zfs.datasets[$name]}"
        eval 'declare -A props='"${dataset[props]}"

        explicitKeylocation=${props[keylocation]:-}
        get-zfs-crypt-props "${dataset[name]}" props cryptKey cryptRoot

        if $zfs get -o value -H name "${dataset[name]}" &>/dev/null ; then # dataset exists: check its properties

            if [[ ${props[mountpoint]:-} ]] ; then # don't set the current mount point again (no-op), cuz that fails if the dataset is mounted
                current=$($zfs get -o value -H mountpoint "${dataset[name]}") ; current=${current/$mnt/}
                if [[ ${props[mountpoint]} == "${current:-/}" ]] ; then unset props[mountpoint] ; fi
            fi
            if [[ ${props[keyformat]:-} == ephemeral ]] ; then
                cryptRoot=${dataset[name]} ; unset props[keyformat] ; props[keylocation]=file:///dev/null
            fi
            if [[ $explicitKeylocation ]] ; then props[keylocation]=$explicitKeylocation ; fi
            unset props[encryption] ; unset props[keyformat] # can't change these anyway
            names=$(IFS=, ; echo "${!props[*]}") ; values=$(IFS=$'\n' ; echo "${props[*]}")
            if [[ $values != "$($zfs get -o value -H "$names" "${dataset[name]}")" ]] ; then (
                declare -a args=( ) ; for name in "${!props[@]}" ; do args+=( "${name}=${props[$name]}" ) ; done
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs set "${args[@]}" "${dataset[name]}" )
            ) ; fi

            if [[ $cryptRoot && $($zfs get -o value -H encryptionroot "${dataset[name]}") != "$cryptRoot" ]] ; then ( # inherit key from parent (which the parent would also already have done if necessary)
                if [[ $($zfs get -o value -H keystatus "$cryptRoot") != available ]] ; then
                    $zfs load-key -L file://"$cryptKey" "$cryptRoot" ; trap "$zfs unload-key $cryptRoot || true" EXIT
                fi
                if [[ $($zfs get -o value -H keystatus "${dataset[name]}") != available ]] ; then
                    $zfs load-key -L file://"$cryptKey" "${dataset[name]}" # will unload with cryptRoot
                fi
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs change-key -i "${dataset[name]}" )
            ) ; fi

        else ( # create dataset
            if [[ ${props[keyformat]:-} == ephemeral ]] ; then
                props[encryption]=aes-256-gcm ; props[keyformat]=hex ; props[keylocation]=file:///dev/stdin ; explicitKeylocation=file:///dev/null
                declare -a args=( ) ; for name in "${!props[@]}" ; do args+=( -o "${name}=${props[$name]}" ) ; done
                </dev/urandom tr -dc 0-9a-f | head -c 64 | ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs create "${args[@]}" "${dataset[name]}" )
                $zfs unload-key "${dataset[name]}"
            else
                if [[ $cryptRoot && $cryptRoot != ${dataset[name]} && $($zfs get -o value -H keystatus "$cryptRoot") != available ]] ; then
                    $zfs load-key -L file://"$cryptKey" "$cryptRoot" ; trap "$zfs unload-key $cryptRoot || true" EXIT
                fi
                declare -a args=( ) ; for name in "${!props[@]}" ; do args+=( -o "${name}=${props[$name]}" ) ; done
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs create "${args[@]}" "${dataset[name]}" )
            fi
            if [[ ${props[canmount]} != off ]] ; then (
                mount -t zfs -o zfsutil "${dataset[name]}" $tmpMnt ; trap "umount '${dataset[name]}'" EXIT
                chmod 000 "$tmpMnt" ; ( chown "${dataset[uid]}:${dataset[gid]}" -- "$tmpMnt" ; chmod "${dataset[mode]}" -- "$tmpMnt" )
            ) ; fi
            if [[ $explicitKeylocation && $explicitKeylocation != "${props[keylocation]:-}" ]] ; then
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs set keylocation="$explicitKeylocation" "${dataset[name]}" )
            fi
            $zfs snapshot -r "${dataset[name]}"@empty
        ) ; fi

        eval 'declare -A allows='"${dataset[permissions]}"
        for who in "${!allows[@]}" ; do
            # »zfs allow $dataset« seems to be the only way to view permissions, and that is not very parsable -.-
            ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs allow -$who "${allows[$who]}" "${dataset[name]}" >&2 )
        done
    done

)}

## Given the name (»datasetPath«) of a ZFS dataset, this deducts crypto-related options from the declared keys (»config.wip.fs.keystore.keys."zfs/..."«).
function get-zfs-crypt-props { # 1: datasetPath, 2?: name_cryptProps, 3?: name_cryptKey, 4?: name_cryptRoot
    local hash=@{config.networking.hostName!hashString.sha256:0:8}
    local keystore=/run/keystore-$hash
    local -n __cryptProps=${2:-props} ; local -n __cryptKey=${3:-cryptKey} ; local -n __cryptRoot=${4:-cryptRoot}

    local name=$1 ; {
        if [[ $name == */* ]] ; then local pool=${name/\/*/}/ ; local path=/${name/$pool/} ; else local pool=$name/ ; local path= ; fi
    } ; local key=${pool/-$hash'/'/}$path # strip hash from pool name

    __cryptKey='' ; __cryptRoot=''
    if [[ @{config.wip.fs.keystore.keys[zfs/$name]:-} ]] ; then
        if [[ @{config.wip.fs.keystore.keys[zfs/$name]} == unencrypted ]] ; then
            __cryptProps[encryption]=off  # empty key to disable encryption
        else
            __cryptProps[encryption]=aes-256-gcm ; __cryptProps[keyformat]=hex ; __cryptProps[keylocation]=file://"$keystore"/zfs/"$name".key
            __cryptKey=$keystore/zfs/$name.key ; __cryptRoot=$name
        fi
    else
        while true ; do
            name=$(dirname $name) ; if [[ $name == . ]] ; then break ; fi
            if [[ @{config.wip.fs.keystore.keys[zfs/$name]:-} ]] ; then
                if [[ @{config.wip.fs.keystore.keys[zfs/$name]} != unencrypted ]] ; then
                    __cryptKey=$keystore/zfs/$name.key ; __cryptRoot=$name
                fi ; break
            fi
        done
    fi
}
