
##
# Key Generation Methods
# See »../../modules/fs/keystore.nix.md« for more documentation.
# It is probably generally advisable that these functions output ASCII strings.
# Keys used as ZFS encryption keys (with the implicit »keyformat = hex«) must be 64 (lowercase?) hex digits.
##

## Outputs nothing (/ an empty key), causing that ZFS dataset to be unencrypted, even if it's parent is encrypted.
function gen-key-unencrypted {( set -eu # 1: usage
    : # TODO: write-secret does not allow empty secrets anymore (might want to change that back)
)}

## Uses the hostname as a trivial key.
function gen-key-hostname {( set -eu # 1: usage
    usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore-@{config.networking.hostName!hashString.sha256:0:8}/.*)$ ]] ; then printf 'The trivial »hostname« key mode is only available for the keystore itself.\n' 1>&2 ; \exit 1 ; fi
    printf %s "@{config.networking.hostName}"
)}

## Obtains a key by reading it from a bootkey partition (see »add-bootkey-to-keydev«).
function gen-key-usb-part {( set -eu # 1: usage
    usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore-[^/]+/[1-8])$ ]] ; then printf '»usb-part« key mode is only available for the keystore itself.\n' 1>&2 ; \exit 1 ; fi
    bootkeyPartlabel=bootkey-"@{config.networking.hostName!hashString.sha256:0:8}"
    cat /dev/disk/by-partlabel/"$bootkeyPartlabel"
)}

## Outputs a key by simply printing an different keystore entry (that must have been generated before).
function gen-key-copy {( set -eu # 1: _, 2: source
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; source=$2
    cat "$keystore"/"$source".key
)}

## Outputs a key by simply using the constant »$value« passed in.
function gen-key-constant {( set -eu # 1: _, 2: value
    value=$2
    printf %s "$value"
)}

## Obtains a key by prompting for a password.
function gen-key-password {( set -eu # 1: usage
    usage=$1
    ( prompt-new-password "as key for @{config.networking.hostName}:$usage" || \exit 1 )
)}

## Generates a key by prompting for (or reusing) a »$user«'s password, combining it with »$keystore/home/$user.key«.
function gen-key-home-composite {( set -eu # 1: usage, 2: user
    keystore=/run/keystore-@{config.networking.hostName!hashString.sha256:0:8} ; usage=$1 ; user=$2
    if [[ ${!userPasswords[@]} && ${userPasswords[$user]:-} ]] ; then
        password=${userPasswords[$user]}
    else
        password=$(prompt-new-password "that will be used as component of the key for »@{config.networking.hostName}:$usage«")
        if [[ ! $password ]] ; then \exit 1 ; fi
    fi
    { cat "$keystore"/home/"$user".key && cat <<<"$password" ; } | sha256sum | head -c 64
)}

## Generates a reproducible, host-independent key by challenging slot »$slot« of YubiKey »$serial« with »$user«'s password.
function gen-key-home-yubikey {( set -eu # 1: usage, 2: serialAndSlotAndUser(as »serial:slot:user«)
    usage=$1 ; args=$2
    serial=$( <<<"$args" cut -d: -f1 ) ; slot=$( <<<"$args" cut -d: -f2 )
    user=${args/$serial:$slot:/}
    if [[ ${!userPasswords[@]} && ${userPasswords[$user]:-} ]] ; then
        password=${userPasswords[$user]}
    else
        password=$(prompt-new-password "as YubiKey challenge for »@{config.networking.hostName}:$usage«")
        if [[ ! $password ]] ; then \exit 1 ; fi
    fi
    gen-key-yubikey-challenge "$usage" "$serial:$slot:home-$user=$password" true "»${user}«'s password (for key »${usage}«)"
)}

## Generates a reproducible secret by prompting for a pin/password and then challenging slot »$slot« of YubiKey »$serial«.
function gen-key-yubikey-pin {( set -eu # 1: usage, 2: serialAndSlot(as »serial:slot«)
    usage=$1 ; serialAndSlot=$2
    pin=$( prompt-new-password "/ pin as challenge to YubiKey »$serialAndSlot« as key for »@{config.networking.hostName}:$usage«" )
    if [[ ! $pin ]] ; then \exit 1 ; fi
    gen-key-yubikey-challenge "$usage" "$serialAndSlot:$pin" true "password / pin as key for »@{config.networking.hostName}:$usage«"
)}

## Generates a reproducible secret for a certain »$use«case and optionally »$salt« on a »$host« by challenging slot »$slot« of YubiKey »$serial«.
function gen-key-yubikey {( set -eu # 1: usage, 2: serialAndSlotAndSalt(as »serial:slot:salt«)
    usage=$1 ; args=$2
    serial=$( <<<"$args" cut -d: -f1 ) ; slot=$( <<<"$args" cut -d: -f2 )
    salt=${args/$serial:$slot:/}
    usagE="$usage" ; if [[ "$usage" =~ ^(luks/.*/[0-8])$ ]] ; then usagE="${usage:0:(-2)}" ; fi # produce the same secret, regardless of the target luks slot
    challenge="@{config.networking.hostName}:$usagE${salt:+:$salt}"
    gen-key-yubikey-challenge "$usage" "$serial:$slot:$challenge"
)}

## Generates a reproducible secret by challenging slot »$slot« of YubiKey »$serial« with the fixed »$challenge«.
function gen-key-yubikey-challenge {( set -eu # 1: _, 2: serialAndSlotAndChallenge(as »$serial:$slot:$challenge«), 3?: onlyOnce, 4?: message
    args=$2 ; message=${4:-}
    serial=$( <<<"$args" cut -d: -f1 ) ; slot=$( <<<"$args" cut -d: -f2 )
    challenge=${args/$serial:$slot:/}

    if [[ "$serial" != "$( @{native.yubikey-personalization}/bin/ykinfo -sq 2>/dev/null )" ]] ; then printf 'Please insert / change to YubiKey with serial %s!\n' "$serial" 1>&2 ; fi
    if [[ ! "${3:-}" ]] ; then
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' twice with '"${message:-challenge »"$challenge":1/2«}"'. Enter to continue, or Ctrl+C to abort:'
    else
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' once with '"${message:-challenge »"$challenge"«}"'. Enter to continue, or Ctrl+C to abort:'
    fi
    if [[ "$serial" != "$( @{native.yubikey-personalization}/bin/ykinfo -sq )" ]] ; then printf 'YubiKey with serial %s not present, aborting.\n' "$serial" 1>&2 ; \exit 1 ; fi

    if [[ ! "${3:-}" ]] ; then
        secret="$( @{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge":1 )""$( sleep .5 || : ; @{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge":2 || @{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge":2 )" # the second consecutive challenge tends to fail if it follows immediately
        if [[ ${#secret} != 80 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" 1>&2 ; \exit 1 ; fi
    else
        secret="$( @{native.yubikey-personalization}/bin/ykchalresp -"$slot" "$challenge" )"
        if [[ ${#secret} != 40 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" 1>&2 ; \exit 1 ; fi
    fi
    { printf %s "$secret" || true ; } | head -c 64
)}

## Generates a random secret key.
function gen-key-random {( set -eu # 1: usage
    </dev/urandom @{native.xxd}/bin/xxd -l 32 -c 64 -p
)}
