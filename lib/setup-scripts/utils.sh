
##
# Utilities
##

## Given the name to an existing bash function, this creates a copy of that function with a new name (in the current scope).
function copy-function { # 1: existingName, 2: newName
    local original=$(declare -f "${1?existingName not provided}") ; if [[ ! $original ]] ; then echo "Function $1 is not defined" 1>&2 ; \return 1 ; fi
    eval "${original/$1/${2?newName not provided}}" # run the code declaring the function again, replacing only the first occurrence of the name
}

## Ensures that a directory exists, like »mkdir -p«, but for any new path elements created, copies the user/group/mode of the closest existing parent.
#  Only uses the fallback user/group/mode when the closest existing parent is already a sticky dir (whose (root-)ownership does not mean much, as it is meant for children owned by any/other user(s), like /tmp).
function mkdir-sticky { # 1: path, 2?: fallbackOwner, 3?: fallbackGroup, 4?: fallbackMode
    local path ; path=$1 ; shift
    if [[ -d $path ]] ; then return ; fi # existing (symlink to existing) dir
    if [[ -L $path || -e $path ]] ; then echo "Can't create (child of) existing file (or broken symlink) '$path'" 1>&2 ; \return 1 ; fi
    local parent ; parent=$( dirname "$path" ) || return
    mkdir-sticky "$parent" "$@" || return
    parent=$( realpath "$parent" ) || return
    stat=( $( stat --format '%u %g %a' "$parent" ) ) || return
    if [[ ${stat[2]} =~ ^1...$ ]] ; then # sticky parent
        #echo "Can't infer correct ownership/permissions for child '$( basename "$path" )' of sticky dir '$parent'" 1>&2 ; return 1
        install --directory --owner="${1:-0}" --group="${2:-0}" ${3+--mode="$3"} "$path" || return
    else
        install --directory --owner=${stat[0]} --group=${stat[1]} --mode=${stat[2]} "$path" || return
    fi
}

## Writes a »$name«d secret from stdin to »$targetDir«, ensuring proper file permissions.
function write-secret {( set -u # 1: path, 2?: owner[:[group]], 3?: mode
    mkdir -p -- "$(dirname "$1")"/ || exit
    install -o root -g root -m 000 -T /dev/null "$1" || exit
    secret=$(tee "$1") # copy stdin to path without removing or adding anything
    if [[ "${#secret}" == 0 ]] ; then echo "write-secret to $1 was empty!" 1>&2 ; \exit 1 ; fi # could also stat the file ...
    chown "${2:-root:root}" -- "$1" || exit
    chmod "${3:-400}"       -- "$1" || exit
)}

## Interactively prompts for a password to be entered and confirmed.
function prompt-new-password {( set -u # 1: usage
    read -s -p "Please enter the new password $1: "     password1 || exit ; echo 1>&2
    if (( ${#password1} == 0 )) ; then printf 'Password empty.\n' 1>&2 ; \exit 1 ; fi
    read -s -p "Please enter the same password again: " password2 || exit ; echo 1>&2
    if [[ "$password1" != "$password2" ]] ; then printf 'Passwords mismatch.\n' 1>&2 ; \exit 1 ; fi
    printf %s "$password1" || exit
)}

## If »secretFile« does not exist, interactively prompts up to three times for the secret to be stored in that file.
declare-flag '*' no-optional-prompts "" "Skip prompting for (and thus saving) secret marked as optional."
function prompt-secret-as {( set -u # 1: what, 2: secretFile, 3?: owner[:[group]], 4?: mode
    if [[ ${arg_optional:-} && ${args[no-optional-prompts]:-} ]] ; then \return ; fi ; if [[ -e $2 ]] ; then \return ; fi
    what=$1 ; shift
    function prompt {
        read -s -p "Please enter $what: " value || exit ; echo 1>&2
        if (( ${#value} == 0 )) ; then printf 'Nothing entered. ' 1>&2 ; \return 1 ; fi
        read -s -p "Please enter that again, or return empty to skip the check: " check || exit ; echo 1>&2
        if [[ $check && $value != "$check" ]] ; then printf 'Entered values mismatch. ' 1>&2 ; \return 1 ; fi
    }
    for attempt in 2 3 x ; do
        if prompt && printf %s "$value" | write-secret "$@" ; then break ; fi
        if [[ $attempt == x ]] ; then echo "Aborting." 1>&2 ; \return 1 ; fi
        echo "Retrying ($attempt/3):" 1>&2
    done
)}

declare-flag install-system inspectScripts "" "When running installation hooks (»...*Commands« composed as Nix strings) print out and pause before each command. This works ... semi-well."

## Runs an installer hook script, optionally stepping through the script.
function run-hook-script {( # 1: title, 2: scriptPath
    trap - EXIT # start with empty traps for sub-shell
    if [[ ${args[inspectScripts]:-} && "$(cat "$2")" != $'' ]] ; then
        echo "Running $1 commands. For each command printed, press Enter to continue or Ctrl+C to abort the installation:" 1>&2
        # (this does not help against intentionally malicious scripts, it's quite easy to trick this)
        BASH_PREV_COMMAND= ; set -o functrace ; trap 'if [[ $BASH_COMMAND != "$BASH_PREV_COMMAND" ]] ; then echo -n "> $BASH_COMMAND" >&2 ; read ; fi ; BASH_PREV_COMMAND=$BASH_COMMAND' debug
    fi
    set -e # The called script snippets should not rely on this, but neither should this function rely on the scripts correctly exiting on errors.
    source "$2"
)}

## Lazily builds a nix derivation at run time, instead of when building the script.
#  When maybe-using packages that take long to build, instead of »at{some.package.out}«, use: »$( build-lazy at{some.package.drvPath!unsafeDiscardStringContext} out )«
function build-lazy { # 1: drvPath, 2?: output
    # Nix v2.14 introduced a new syntax for selecting the output of multi-output derivations, v2.15 then changed the default when passing the path to an on-disk derivation. »--print-out-paths« is also not available in older versions.
    if version-gr-eq "@{native.nix.version}" '2.14' ; then
        PATH=$PATH:@{native.openssh}/bin @{native.nix}/bin/nix --extra-experimental-features nix-command build --no-link --print-out-paths ${args[quiet]:+--quiet} "$1"'^'"${2:-out}"
    else
        PATH=$PATH:@{native.openssh}/bin @{native.nix}/bin/nix --extra-experimental-features nix-command build --no-link --json ${args[quiet]:+--quiet} "$1" | @{native.jq}/bin/jq -r .[0].outputs."${2:-out}"
    fi
}

## Tests whether (returns 0/success if) the first version argument is greater/less than (or equal) the second version argument.
function version-gr-eq { printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -C -V -r ; }
function version-lt-eq { printf '%s\n%s' "$1" "$2" | LC_ALL=C sort -C -V ; }
function version-gt { ! version-gt-eq "$2" "$1" ; }
function version-lt { ! version-lt-eq "$2" "$1" ; }
