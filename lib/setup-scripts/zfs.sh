
## Creates all of the system's ZFS pools that are »createDuringInstallation«, plus their datasets.
function create-zpools { # 1: mnt
    local poolName ; for poolName in "@{!config.setup.zfs.pools[@]}" ; do
        if [[ ! @{config.setup.zfs.pools!catAttrSets.createDuringInstallation[$poolName]} ]] ; then continue ; fi
        create-zpool "$1" "$poolName"
    done
}


declare-command create-zpool mnt poolName << 'EOD'
Creates a single of the system's ZFS pools, and its datasets. Can be called manually to create pools that were added to the configuration, or to create those declared with »createDuringInstallation = false«. Expects the backing device(-partition)s to exist as declared for the pool.
EOD
declare-flag install-system zpool-force "" "(create-zpool) When creating ZFS storage pools, pass the »-f« (force) option. This may be required when installing to disks that are currently part of a pool, or ZFS refuses do reuse them."
function create-zpool {
    local mnt=$1 ; local poolName=$2
    eval 'local -A pool='"@{config.setup.zfs.pools[$poolName]}"
    eval 'local -a vdevs='"${pool[vdevArgs]}"
    eval 'local -A poolProps='"${pool[props]}"
    eval 'local -A dataset='"@{config.setup.zfs.datasets[${pool[name]}]}"
    eval 'local -A dataProps='"${dataset[props]}"
    local dummy ; get-zfs-crypt-props "${dataset[name]}" dataProps dummy dummy
    local -a zpoolCreate=( ) ; keySrc=/dev/null
    if [[ ${dataProps[keyformat]:-} == ephemeral ]] ; then
        dataProps[encryption]=aes-256-gcm ; dataProps[keyformat]=hex ; dataProps[keylocation]=file:///dev/stdin ; keySrc=/dev/urandom
    fi
    local name ; for name in "${!poolProps[@]}" ; do zpoolCreate+=( -o "${name}=${poolProps[$name]}" ) ; done
    local name ; for name in "${!dataProps[@]}" ; do zpoolCreate+=( -O "${name}=${dataProps[$name]}" ) ; done
    local index ; for index in "${!vdevs[@]}" ; do
        part=${vdevs[$index]} ; if [[ $part =~ ^(mirror|raidz[123]?|draid[123]?.*|spare|log|dedup|special|cache)$ ]] ; then continue ; fi
        if [[ @{config.boot.initrd.luks.devices!catAttrSets.device[$part]:-} ]] ; then
            vdevs[$index]=/dev/mapper/$part
        else
            part=/dev/disk/by-partlabel/$part ; vdevs[$index]=$part
            if ! is-partition-on-disks "$part" "${blockDevs[@]}" ; then echo "Partition alias $part used by zpool ${pool[name]} does not point at one of the target disks ${blockDevs[@]}" 1>&2 ; \return 1 ; fi
        fi
    done
    @{native.kmod}/bin/modprobe zfs || true
    <$keySrc @{native.xxd}/bin/xxd -l 32 -c 64 -p | ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zpool create ${args[zpool-force]:+-f} "${zpoolCreate[@]}" -R "$mnt" "${pool[name]}" "${vdevs[@]}" ) || return
    prepend_trap "@{native.zfs}/bin/zpool export '$poolName'" EXIT || return
    if [[ $keySrc == /dev/urandom ]] ; then @{native.zfs}/bin/zfs unload-key "$poolName" &>/dev/null ; fi

    ensure-datasets $mnt '^'"$poolName"'($|[/])' || return
    if [[ ${args[debug]:-} ]] ; then @{native.zfs}/bin/zfs list -o name,canmount,mounted,mountpoint,keystatus,encryptionroot -r "$poolName" ; fi
}

declare-command ensure-datasets mnt filterExp? << 'EOD'
Ensures that the system's datasets exist and have the defined properties (but not that they don't have properties that aren't defined).
The pool(s) must exist, be imported with root prefix »$mnt«, and (if datasets are to be created or encryption roots to be inherited) the system's keystore must be open (see »mount-keystore-luks«) or the keys must be loaded.
»keystatus« and »mounted« of existing datasets should remain unchanged by this function, newly crated datasets will not be mounted but have their keys loaded.
EOD
function ensure-datasets {
    if (( @{#config.setup.zfs.datasets[@]} == 0 )) ; then \return ; fi
    local mnt=$1 ; while [[ "$mnt" == */ ]] ; do mnt=${mnt:0:(-1)} ; done # (remove any tailing slashes)
    local filterExp=${2:-'^'}
    local zfs=@{native.zfs}/bin/zfs

    local name ; while IFS= read -u3 -r -d $'\0' name ; do
        if  [[ ! $name =~ $filterExp ]] ; then : "Skipping dataset »$name« since it does not match »$filterExp«" ; continue ; fi

        eval 'local -A dataset='"@{config.setup.zfs.datasets[$name]}"
        eval 'local -A props='"${dataset[props]}"

        local explicitKeylocation=${props[keylocation]:-} cryptKey cryptRoot
        get-zfs-crypt-props "${dataset[name]}" props cryptKey cryptRoot

        if $zfs get -o value -H name "${dataset[name]}" &>/dev/null ; then # dataset exists: check its properties

            if [[ ${props[mountpoint]:-} ]] ; then # don't set the current mount point again (no-op), cuz that fails if the dataset is mounted
                local current=$($zfs get -o value -H mountpoint "${dataset[name]}") ; current=${current/$mnt/}
                if [[ ${props[mountpoint]} == "${current:-/}" ]] ; then unset props[mountpoint] ; fi
            fi
            if [[ ${props[keyformat]:-} == ephemeral ]] ; then
                cryptRoot= ; unset props[keyformat] ; props[keylocation]=file:///dev/null
            fi
            if [[ $explicitKeylocation ]] ; then props[keylocation]=$explicitKeylocation ; fi
            unset props[encryption] ; unset props[keyformat] # can't change these anyway

            function ensure-props { # 1: datasetName
                local datasetName=$1
                local propNames=$( IFS=, ; echo "${!props[*]}" )
                local propValues=$( IFS=$'\n' ; echo "${props[*]}" )
                if [[ $propValues != "$( $zfs get -o value -H "$propNames" "$datasetName" )" ]] ; then
                    local -a zfsSet=( ) ; local propName ; for propName in "${!props[@]}" ; do zfsSet+=( "${propName}=${props[$propName]}" ) ; done
                    ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs set "${zfsSet[@]}" "$datasetName" ) || return
                fi
                if [[ $cryptRoot && $( $zfs get -o value -H encryptionroot "$datasetName" ) != "$cryptRoot" ]] ; then ( # inherit key from parent (which the parent would also already have done if necessary)
                    if [[ $( $zfs get -o value -H keystatus "$cryptRoot" ) != available ]] ; then
                        $zfs load-key -L file://"$cryptKey" "$cryptRoot" || exit ; trap "$zfs unload-key $cryptRoot || true" EXIT
                    fi
                    if [[ $( $zfs get -o value -H keystatus "$datasetName" ) != available ]] ; then
                        $zfs load-key -L file://"$cryptKey" "$datasetName" || exit # will unload with cryptRoot
                    fi
                    ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs change-key -i "$datasetName" ) || exit
                ) || return ; fi
            }
            ensure-props "${dataset[name]}" || return

            if [[ ${dataset[recursiveProps]:-} ]] ; then
                if [[ ${props[mountpoint]:-} != none ]] ; then unset props[mountpoint] ; fi
                while IFS= read -u3 -r name ; do
                    ensure-props "$name" || return
                done 3< <( $zfs list -H -o name -r "${dataset[name]}" | LC_ALL=C sort | tail -n +2 )
            fi

        else ( # create dataset
            if [[ ${props[keyformat]:-} == ephemeral ]] ; then
                props[encryption]=aes-256-gcm ; props[keyformat]=hex ; props[keylocation]=file:///dev/stdin ; explicitKeylocation=file:///dev/null
                declare -a zfsCreate=( ) ; for name in "${!props[@]}" ; do zfsCreate+=( -o "${name}=${props[$name]}" ) ; done
                { </dev/urandom tr -dc 0-9a-f || true ; } | head -c 64 | ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs create "${zfsCreate[@]}" "${dataset[name]}" ) || exit
                $zfs unload-key "${dataset[name]}" || exit
            else
                if [[ $cryptRoot && $cryptRoot != ${dataset[name]} && $($zfs get -o value -H keystatus "$cryptRoot") != available ]] ; then
                    $zfs load-key -L file://"$cryptKey" "$cryptRoot" || exit
                    trap "$zfs unload-key $cryptRoot || true" EXIT
                fi
                declare -a zfsCreate=( ) ; for name in "${!props[@]}" ; do zfsCreate+=( -o "${name}=${props[$name]}" ) ; done
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs create "${zfsCreate[@]}" "${dataset[name]}" ) || exit
            fi
            if [[ ${props[canmount]} != off ]] ; then (
                tmp=$( mktemp -d ) && mkdir $tmp/mnt && @{native.util-linux}/bin/mount -t zfs -o zfsutil "${dataset[name]}" $tmp/mnt || exit
                trap "@{native.util-linux}/bin/umount '${dataset[name]}' ; rmdir $tmp{/mnt,}" EXIT || exit
                chmod 000 -- $tmp/mnt && ( cd $tmp ; chown "${dataset[uid]}:${dataset[gid]}" -- mnt && chmod "${dataset[mode]}" -- mnt ) || exit
            ) || exit ; fi
            if [[ $explicitKeylocation && $explicitKeylocation != "${props[keylocation]:-}" ]] ; then
                ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs set keylocation="$explicitKeylocation" "${dataset[name]}" ) || exit
            fi
            $zfs snapshot -r "${dataset[name]}"@empty || exit
        ) || return ; fi

        eval 'local -A allows='"${dataset[permissions]}"
        for who in "${!allows[@]}" ; do
            # »zfs allow $dataset« seems to be the only way to view permissions, and that is not very parsable -.-
            ( PATH=@{native.zfs}/bin ; ${_set_x:-:} ; zfs allow -$who "${allows[$who]}" "${dataset[name]}" >&2 ) || return
        done
    done 3< <( printf '%s\0' "@{!config.setup.zfs.datasets[@]}" | LC_ALL=C sort -z )
}

## Given the name (»datasetPath«) of a ZFS dataset, this deducts crypto-related options from the declared keys (»config.setup.keystore.keys."zfs/..."«).
function get-zfs-crypt-props { # 1: datasetPath, 2?: name_cryptProps, 3?: name_cryptKey, 4?: name_cryptRoot
    local hash=@{config.networking.hostName!hashString.sha256:0:8}
    local keystore=/run/keystore-$hash
    local -n __cryptProps=${2:-props} ; local -n __cryptKey=${3:-cryptKey} ; local -n __cryptRoot=${4:-cryptRoot}

    local name=$1 ; {
        if [[ $name == */* ]] ; then local pool=${name/\/*/}/ ; local path=/${name/$pool/} ; else local pool=$name/ ; local path= ; fi
    } ; local key=${pool/-$hash'/'/}$path # strip hash from pool name

    __cryptKey='' ; __cryptRoot=''
    if [[ @{config.setup.keystore.keys[zfs/$name]:-} ]] ; then
        if [[ @{config.setup.keystore.keys[zfs/$name]} == unencrypted ]] ; then
            __cryptProps[encryption]=off  # empty key to disable encryption
        else
            __cryptProps[encryption]=aes-256-gcm ; __cryptProps[keyformat]=hex ; __cryptProps[keylocation]=file://"$keystore"/zfs/"$name".key
            __cryptKey=$keystore/zfs/$name.key ; __cryptRoot=$name
        fi
    else
        while true ; do
            name=$(dirname $name) ; if [[ $name == . ]] ; then break ; fi
            if [[ @{config.setup.keystore.keys[zfs/$name]:-} ]] ; then
                if [[ @{config.setup.keystore.keys[zfs/$name]} != unencrypted ]] ; then
                    __cryptKey=$keystore/zfs/$name.key ; __cryptRoot=$name
                fi ; break
            fi
        done
    fi
}
