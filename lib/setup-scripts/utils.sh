
##
# Utilities
##

## Performs a simple and generic parsing of CLI arguments. Creates a global associative array »args« and a global normal array »argv«.
#  Named options may be passed as »--name[=value]«, where »value« defaults to »1«, and are assigned to »args«.
#  Everything else, or everything following the »--« argument, ends up as positional arguments in »argv«.
#  Checking the validity of the parsed arguments is up to the caller.
function generic-arg-parse { # ...
    declare -g -A args=( ) ; declare -g -a argv=( ) # this ends up in the caller's scope
    while (( "$#" )) ; do
        if [[ $1 == -- ]] ; then shift ; argv+=( "$@" ) ; return ; fi
        if [[ $1 == --* ]] ; then
            if [[ $1 == *=* ]] ; then
                local key=${1/=*/} ; args[${key/--/}]=${1/$key=/}
            else args[${1/--/}]=1 ; fi
        else argv+=( "$1" ) ; fi
    shift ; done
}

## Prepends a command to a trap. Especially useful fo define »finally« commands via »prepend_trap '<command>' EXIT«.
#  NOTE: When calling this in a sub-shell whose parents already has traps installed, make sure to do »trap - trapName« first. On a new shell, this should be a no-op, but without it, the parent shell's traps will be added to the sub-shell as well (due to strange behavior of »trap -p« (in bash ~5.1.8)).
prepend_trap() { # 1: command, ...: trapNames
    fatal() { printf "ERROR: $@\n" >&2 ; return 1 ; }
    local cmd=$1 ; shift || fatal "${FUNCNAME} usage error"
    local name ; for name in "$@" ; do
        trap -- "$( set +x
            printf '%s\n' "( ${cmd} ) || true ; "
            p3() { printf '%s\n' "${3:-}" ; } ; eval "p3 $(trap -p "${name}")"
        )" "${name}" || fatal "unable to add to trap ${name}"
    done
} ; declare -f -t prepend_trap # required to modify DEBUG or RETURN traps


## Writes a »$name«d secret from stdin to »$targetDir«, ensuring proper file permissions.
function write-secret {( set -eu # 1: path, 2?: owner[:[group]], 3?: mode
    mkdir -p -- "$(dirname "$1")"/
    install -o root -g root -m 000 -T /dev/null "$1"
    secret=$(tee "$1") # copy stdin to path without removing or adding anything
    if [[ "${#secret}" == 0 ]] ; then echo "write-secret to $1 was empty!" 1>&2 ; exit 1 ; fi # could also stat the file ...
    chown "${2:-root:root}" -- "$1"
    chmod "${3:-400}"       -- "$1"
)}

## Interactively prompts for a password to be entered and confirmed.
function prompt-new-password {( set -eu # 1: usage
    usage=$1
    read -s -p "Please enter the new password $usage: " password1 ; echo 1>&2
    read -s -p "Please enter the same password again: " password2 ; echo 1>&2
    if (( ${#password1} == 0 )) || [[ "$password1" != "$password2" ]] ; then printf 'Passwords empty or mismatch, aborting.\n' 1>&2 ; exit 1 ; fi
    printf %s "$password1"
)}

## Runs an installer hook script, optionally stepping through the script.
function run-hook-script {( set -eu # 1: title, 2: scriptPath
    trap - EXIT # start with empty traps for sub-shell
    if [[ ${args[inspectScripts]:-} && "$(cat "$2")" != $'' ]] ; then
        echo "Running $1 commands. For each command printed, press Enter to continue or Ctrl+C to abort the installation:"
        # (this does not help against intentionally malicious scripts, it's quite easy to trick this)
        BASH_PREV_COMMAND= ; set -o functrace ; trap 'if [[ $BASH_COMMAND != "$BASH_PREV_COMMAND" ]] ; then echo -n "> $BASH_COMMAND" >&2 ; read ; fi ; BASH_PREV_COMMAND=$BASH_COMMAND' debug
    fi
    source "$2"
)}
