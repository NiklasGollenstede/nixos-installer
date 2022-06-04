
##
# Key Generation Methods
# See »../../modules/fs/keystore.nix.md« for more documentation.
##

## Puts an empty key in the keystore, causing that ZFS dataset to be unencrypted, even if it's parent is encrypted.
function add-key-unencrypted {( set -eu # 1: usage
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1
    : | write-secret "$keystore"/"$usage".key
)}

## Adds a key by copying the hostname to the keystore.
function add-key-hostname {( set -eu # 1: usage
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore-@{config.networking.hostName!hashString.sha256:0:8}/.*)$ ]] ; then printf '»trivial« key mode is only available for the keystore itself.\n' ; exit 1 ; fi
    printf %s "@{config.networking.hostName}" | write-secret "$keystore"/"$usage".key
)}

## Adds a key by copying it from a bootkey partition (see »add-bootkey-to-keydev«) to the keystore.
function add-key-usb-part {( set -eu # 1: usage
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore-[^/]+/[1-8])$ ]] ; then printf '»usb-part« key mode is only available for the keystore itself.\n' ; exit 1 ; fi
    bootkeyPartlabel=bootkey-"@{config.networking.hostName!hashString.sha256:0:8}"
    cat /dev/disk/by-partlabel/"$bootkeyPartlabel" | write-secret "$keystore"/"$usage".key
)}

## Adds a key by copying a different key from the keystore to the keystore.
function add-key-copy {( set -eu # 1: usage, 2: source
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1 ; source=$2
    cat "$keystore"/"$source".key | write-secret "$keystore"/"$usage".key
)}

## Adds a key by writing a constant value to the keystore.
function add-key-constant {( set -eu # 1: usage, 2: value
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1 ; value=$2
    printf %s "$value" | write-secret "$keystore"/"$usage".key
)}

## Adds a key by prompting for a password and saving it to the keystore.
function add-key-password {( set -eu # 1: usage
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1
    (prompt-new-password "as key for @{config.networking.hostName}/$usage" || exit 1) \
    | write-secret "$keystore"/"$usage".key
)}

## Generates a key by prompting for a password, combining it with »$keystore/home/$user.key«, and saving it to the keystore.
function add-key-home-pw {( set -eu # 1: usage, 2: user
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1 ; user=$2
    if  [[ ${!userPasswords[@]} && ${userPasswords[$user]:-} ]] ; then
        password=${userPasswords[$user]}
    else
        password=$(prompt-new-password "that will be used as component of the key for @{config.networking.hostName}/$usage")
    fi
    ( cat "$keystore"/home/"$user".key && cat <<<"$password" ) | sha256sum | head -c 64 \
    | write-secret "$keystore"/"$usage".key
)}

## Generates a reproducible secret for a certain »$use«case by prompting for a pin/password and then challenging slot »$slot« of YubiKey »$serial«, and saves it to the »$keystore«.
function add-key-yubikey-pin {( set -eu # 1: usage, 2: serialAndSlot(as »serial:slot«)
    usage=$1 ; serialAndSlot=$2
    password=$(prompt-new-password "/ pin as challenge to YubiKey »$serialAndSlot« as key for @{config.networking.hostName}/$usage")
    add-key-yubikey-challenge "$usage" "$serialAndSlot:$password" true "pin for ${usage}"
)}

## Generates a reproducible secret for a certain »$use«case on a »$host« by challenging slot »$slot« of YubiKey »$serial«, and saves it to the »$keystore«.
function add-key-yubikey {( set -eu # 1: usage, 2: serialAndSlotAndSalt(as »serial:slot:salt«)
    usage=$1 ; IFS=':' read -ra serialAndSlotAndSalt <<< "$2"
    usage_="$usage" ; if [[ "$usage" =~ ^(luks/.*/[0-8])$ ]] ; then usage_="${usage:0:(-2)}" ; fi # produce the same secret, regardless of the target luks slot
    challenge="@{config.networking.hostName}:$usage_${serialAndSlotAndSalt[2]:+:${serialAndSlotAndSalt[2]:-}}"
    add-key-yubikey-challenge "$usage" "${serialAndSlotAndSalt[0]}:${serialAndSlotAndSalt[1]}:$challenge"
)}

## Generates a reproducible secret for a certain »$use«case by challenging slot »$slot« of YubiKey »$serial« with the fixed »$challenge«, and saves it to the »$keystore«.
#  If »$sshArgs« is set as (env) var, generate the secret locally, then use »ssh $sshArgs« to write the secret on the other end.
#  E.g.: # sshArgs='installerIP' add-key-yubikey /run/keystore/ zfs/rpool/remote 1234567:2:customChallenge
function add-key-yubikey-challenge {( set -eu # 1: usage, 2: serialAndSlotAndChallenge(as »$serial:$slot:$challenge«), 3?: onlyOnce, 4?: message
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1 ; args=$2 ; message=${4:-}
    serial=$(<<<"$args" cut -d: -f1)
    slot=$(<<<"$args" cut -d: -f2)
    challenge=${args/$serial:$slot:/}

    if [[ "$serial" != "$(@{native.yubikey-personalization}/bin/ykinfo -sq)" ]] ; then printf 'Please insert / change to YubiKey with serial %s!\n' "$serial" ; fi
    if [[ ! "${3:-}" ]] ; then
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' twice with '"${message:-challenge »"$challenge":1/2«}"'. Enter to continue, or Ctrl+C to abort:'
    else
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' once with '"${message:-challenge »"$challenge"«}"'. Enter to continue, or Ctrl+C to abort:'
    fi
    if [[ "$serial" != "$(@{native.yubikey-personalization}/bin/ykinfo -sq)" ]] ; then printf 'YubiKey with serial %s not present, aborting.\n' "$serial" ; exit 1 ; fi

    if [[ ! "${3:-}" ]] ; then
        secret="$(@{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge":1)""$(@{native.yubikey-personalization}/bin/ykchalresp -2 "$challenge":2)"
        if [[ ${#secret} != 80 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" ; exit 1 ; fi
    else
        secret="$(@{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge")"
        if [[ ${#secret} != 40 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" ; exit 1 ; fi
    fi
    if [[ ! "${sshArgs:-}" ]] ; then
        printf %s "$secret" | ( head -c 64 | write-secret "$keystore"/"$usage".key )
    else
        read -p 'Uploading secret with »ssh '"$sshArgs"'«. Enter to continue, or Ctrl+C to abort:'
        printf %s "$secret" | ( head -c 64 | ssh $sshArgs /etc/nixos/utils/functions.sh write-secret "$keystore"/"$usage".key )
    fi
)}

## Generates a random secret key and saves it to the keystore.
function add-key-random {( set -eu # 1: usage
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1
    </dev/urandom tr -dc 0-9a-f | head -c 64 | write-secret "$keystore"/"$usage".key
)}
