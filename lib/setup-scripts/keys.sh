

## Prompts for the password of every user that uses a »passwordFile«, to later use that password for home encryption and/or save it in the »passwordFile«.
function prompt-for-user-passwords { # (void)
    declare -g -A userPasswords=( ) # (this ends up in the caller's scope)
    for user in "@{!config.users.users!catAttrSets.password[@]}" ; do # Also grab any plaintext passwords for testing setups.
        userPasswords[$user]=@{config.users.users!catAttrSets.password[$user]}
    done
    for user in "@{!config.users.users!catAttrSets.passwordFile[@]}" ; do
        if ! userPasswords[$user]=$(prompt-new-password "for the user account »$user«") ; then true ; \return 1 ; fi
    done
}


## Mounts a ramfs as the host's keystore and populates it with keys as requested by »config.wip.fs.keystore.keys«.
#  Depending on the specified key types/sources, this may prompt for user input.
function populate-keystore { { # (void)
    local keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}

    mkdir -p $keystore && chmod 750 $keystore && prepend_trap "rmdir $keystore" EXIT
    mount ramfs -t ramfs $keystore && prepend_trap "umount $keystore" EXIT
} && ( set -eu

    declare -A methods=( ) ; declare -A options=( )
    for usage in "@{!config.wip.fs.keystore.keys[@]}" ; do
        methodAndOptions="@{config.wip.fs.keystore.keys[$usage]}"
        method=$(<<<"$methodAndOptions" cut -d= -f1)
        methods[$usage]=$method ; options[$usage]=${methodAndOptions/$method=/} # TODO: if no options are provided, this passes the method string as options (use something like ${methodAndOptions:(- $(( ${#method} + 1 ))})
    done

    for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != inherit ]] ; then continue ; fi
        from=${options[$usage]}
        methods[$usage]=${methods[$from]} ; options[$usage]=${options[$from]}
    done
    for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" == home-composite || "${methods[$usage]}" == copy ]] ; then continue ; fi
        for attempt in 2 3 x ; do
            if gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key ; then break ; fi
            if [[ $attempt == x ]] ; then \exit 1 ; fi ; echo "Retrying ($attempt/3):"
        done
    done
    for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != home-composite ]] ; then continue ; fi
        gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key || \exit 1
    done
    for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != copy ]] ; then continue ; fi
        gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key || \exit 1
    done
)}


## Creates the LUKS devices specified by the host using the keys created by »populate-keystore«.
function create-luks-layers { # (void)
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}
    for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        rawDev=@{config.boot.initrd.luks.devices!catAttrSets.device[$luksName]}
        if ! is-partition-on-disks "$rawDev" "${blockDevs[@]}" ; then echo "Partition alias $rawDev used by LUKS device $luksName does not point at one of the target disks ${blockDevs[@]}" 1>&2 ; \return 1 ; fi
        primaryKey="$keystore"/luks/"$luksName"/0.key

        keyOptions=( --pbkdf=pbkdf2 --pbkdf-force-iterations=1000 )
        ( PATH=@{native.cryptsetup}/bin ; ${_set_x:-:} ; cryptsetup --batch-mode luksFormat --key-file="$primaryKey" "${keyOptions[@]}" -c aes-xts-plain64 -s 512 -h sha256 "$rawDev" ) || return
        for index in 1 2 3 4 5 6 7 ; do
            if [[ -e "$keystore"/luks/"$luksName"/"$index".key ]] ; then
                ( PATH=@{native.cryptsetup}/bin ; ${_set_x:-:} ; cryptsetup luksAddKey --key-file="$primaryKey" "${keyOptions[@]}" "$rawDev" "$keystore"/luks/"$luksName"/"$index".key ) || return
            fi
        done
    done
}

## Opens the LUKS devices specified by the host, using the opened host's keystore.
function open-luks-layers { # (void)
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}
    for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e /dev/mapper/$luksName ]] ; then continue ; fi
        rawDev=@{config.boot.initrd.luks.devices!catAttrSets.device[$luksName]}
        primaryKey="$keystore"/luks/"$luksName"/0.key
        @{native.cryptsetup}/bin/cryptsetup --batch-mode luksOpen --key-file="$primaryKey" "$rawDev" "$luksName" || return
        prepend_trap "@{native.cryptsetup}/bin/cryptsetup close $luksName" EXIT || return
    done
}
