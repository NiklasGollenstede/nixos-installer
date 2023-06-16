

## Prompts for the password of every user that uses a »passwordFile«, to later use that password for home encryption and/or save it in the »passwordFile«.
function prompt-for-user-passwords { # (void)
    declare -g -A userPasswords=( ) # (this ends up in the caller's scope)
    local user ; for user in "@{!config.users.users!catAttrSets.password[@]}" ; do # Also grab any plaintext passwords for testing setups.
        userPasswords[$user]=@{config.users.users!catAttrSets.password[$user]}
    done
    local user ; for user in "@{!config.users.users!catAttrSets.passwordFile[@]}" ; do
        if ! userPasswords[$user]=$(prompt-new-password "for the user account »$user«") ; then true ; \return 1 ; fi
    done
}


## Mounts a ramfs as the host's keystore and populates it with keys as requested by »config.setup.keystore.keys«.
#  Depending on the specified key types/sources, this may prompt for user input.
function populate-keystore { # (void)
    local keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}

    mkdir -p $keystore && chmod 750 $keystore && prepend_trap "rmdir $keystore" EXIT || return
    @{native.util-linux}/bin/mount ramfs -t ramfs $keystore && prepend_trap "@{native.util-linux}/bin/umount $keystore" EXIT || return

    local -A methods=( ) ; local -A options=( )
    local usage ; for usage in "@{!config.setup.keystore.keys[@]}" ; do
        methods[$usage]=@{config.setup.keystore.keys[$usage]%%=*}
        options[$usage]=@{config.setup.keystore.keys[$usage]:$(( ${#methods[$usage]} + 1 ))}
    done

    local usage ; for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != inherit ]] ; then continue ; fi
        local from=${options[$usage]}
        methods[$usage]=${methods[$from]} ; options[$usage]=${options[$from]}
    done
    local usage ; for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" == home-composite || "${methods[$usage]}" == copy ]] ; then continue ; fi
        local attempt ; for attempt in 2 3 x ; do
            if gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key ; then break ; fi
            if [[ $attempt == x ]] ; then \return 1 ; fi ; echo "Retrying ($attempt/3):"
        done
    done
    local usage ; for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != home-composite ]] ; then continue ; fi
        gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key || return
    done
    local usage ; for usage in "${!methods[@]}" ; do
        if [[ "${methods[$usage]}" != copy ]] ; then continue ; fi
        gen-key-"${methods[$usage]}" "$usage" "${options[$usage]}" | write-secret "$keystore"/"$usage".key || return
    done
}


## Creates the LUKS devices specified by the host using the keys created by »populate-keystore«.
function create-luks-layers { # (void)
    local keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}
    for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        local rawDev=@{config.boot.initrd.luks.devices!catAttrSets.device[$luksName]}
        if ! is-partition-on-disks "$rawDev" "${blockDevs[@]}" ; then echo "Partition alias $rawDev used by LUKS device $luksName does not point at one of the target disks ${blockDevs[@]}" 1>&2 ; \return 1 ; fi
        local primaryKey="$keystore"/luks/"$luksName"/0.key

        local keyOptions=( --pbkdf=pbkdf2 --pbkdf-force-iterations=1000 )
        ( PATH=@{native.cryptsetup}/bin ; ${_set_x:-:} ; cryptsetup --batch-mode luksFormat --key-file="$primaryKey" "${keyOptions[@]}" -c aes-xts-plain64 -s 512 -h sha256 "$rawDev" ) || return
        local index ; for index in 1 2 3 4 5 6 7 ; do
            if [[ -e "$keystore"/luks/"$luksName"/"$index".key ]] ; then
                ( PATH=@{native.cryptsetup}/bin ; ${_set_x:-:} ; cryptsetup luksAddKey --key-file="$primaryKey" "${keyOptions[@]}" "$rawDev" "$keystore"/luks/"$luksName"/"$index".key ) || return
            fi
        done
    done
}

## Opens the LUKS devices specified by the host, using the host's (open) keystore.
function open-luks-layers { # (void)
    local keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8}
    for luksName in "@{!config.boot.initrd.luks.devices!catAttrSets.device[@]}" ; do
        if [[ -e /dev/mapper/$luksName ]] ; then continue ; fi
        local rawDev=@{config.boot.initrd.luks.devices!catAttrSets.device[$luksName]}
        local primaryKey="$keystore"/luks/"$luksName"/0.key
        @{native.cryptsetup}/bin/cryptsetup --batch-mode luksOpen --key-file="$primaryKey" "$rawDev" "$luksName" || return
        prepend_trap "@{native.cryptsetup}/bin/cryptsetup close $luksName" EXIT || return
    done
}
