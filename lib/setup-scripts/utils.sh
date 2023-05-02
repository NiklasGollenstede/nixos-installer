
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
        if [[ $1 == -- ]] ; then shift ; argv+=( "$@" ) ; \return 0 ; fi
        if [[ $1 == --* ]] ; then
            if [[ $1 == *=* ]] ; then
                local key=${1/=*/} ; args[${key/--/}]=${1/$key=/}
            else args[${1/--/}]=1 ; fi
        else argv+=( "$1" ) ; fi
    shift ; done
}

## Shows the help text for a program and exits, if »--help« was passed as argument and parsed, or does nothing otherwise.
#  Expects to be called between parsing and verifying the arguments.
#  Uses »allowedArgs« for the list of the named arguments (the values are the descriptions).
#  »name« should be the program name/path (usually »$0«), »args« the form/names of any positional arguments expected (e.g. »SOURCE... DEST«) and is included in the "Usage" description,
#  »description« the introductory text shown before the "Usage", and »suffix« any text printed after the argument list.
function generic-arg-help { # 1: name, 2?: args, 3?: description, 4?: suffix
    if [[ ! ${args[help]:-} ]] ; then : ${allowedArgs[help]:=1} ; \return 0 ; fi
    [[ ! ${3:-} ]] || echo "$3"
    printf 'Usage:\n    %s [ARG[=value]]... [--] %s\n\nWhere »ARG« may be any of:\n' "$1" "${2:-}"
    local name ; while IFS= read -u3 -r name ; do
        printf '    %s\n        %s\n' "$name" "${allowedArgs[$name]}"
    done 3< <( printf '%s\n' "${!allowedArgs[@]}" | LC_ALL=C sort )
    printf '    %s\n        %s\n' "--help" "Do nothing but print this message and exit with success."
    [[ ! ${4:-} ]] || echo "$4"
    \exit 0
}

## Performs a basic verification of the named arguments passed by the user and parsed by »generic-arg-parse« against the names in »allowedArgs«.
#  Entries in »allowedArgs« should have the form »[--name]="description"« for boolean flags, and »[--name=VAL]="description"« for string arguments.
#  »description« is used by »generic-arg-help«. Boolean flags may only have the values »1« (as set by »generic-ags-parse« for flags without value) or be empty.
#  »VAL« is purely nominal. Any argument passed that is not in »allowedArgs« raises an error.
function generic-arg-verify { # 1: exitCode
    local exitCode=${1:-1}
    local names=' '"${!allowedArgs[@]}"
    for name in "${!args[@]}" ; do
        if [[ ${allowedArgs[--$name]:-} ]] ; then
            if [[ ${args[$name]} == '' || ${args[$name]} == 1 ]] ; then continue ; fi
            echo "Argument »--$name« should be a boolean, but its value is: ${args[$name]}" 1>&2 ; \return $exitCode
        fi
        if [[ $names == *' --'"$name"'='* || $names == *' --'"$name"'[='* ]] ; then continue ; fi
        echo "Unexpected argument »--$name«.${allowedArgs[help]:+ Call with »--help« for a list of valid arguments.}" 1>&2 ; \return $exitCode
    done
}

## Prepends a command to a trap. Especially useful fo define »finally« commands via »prepend_trap '<command>' EXIT«.
#  NOTE: When calling this in a sub-shell whose parents already has traps installed, make sure to do »trap - trapName« first. On a new shell, this should be a no-op, but without it, the parent shell's traps will be added to the sub-shell as well (due to strange behavior of »trap -p« (in bash ~5.1.8)).
function prepend_trap { # 1: command, ...: trapNames
    fatal() { printf "ERROR: $@\n" 1>&2 ; \return 1 ; }
    local cmd=$1 ; shift 1 || fatal "${FUNCNAME} usage error"
    local name ; for name in "$@" ; do
        trap -- "$( set +x
            printf '%s\n' "( ${cmd} ) || true ; "
            p3() { printf '%s\n' "${3:-}" ; }
            eval "p3 $(trap -p "${name}")"
        )" "${name}" || fatal "unable to add to trap ${name}"
    done
}
declare -f -t prepend_trap # required to modify DEBUG or RETURN traps

## Given the name to an existing bash function, this creates a copy of that function with a new name (in the current scope).
function copy-function { # 1: existingName, 2: newName
    local original=$(declare -f "${1?existingName not provided}") ; if [[ ! $original ]] ; then echo "Function $1 is not defined" 1>&2 ; \return 1 ; fi
    eval "${original/$1/${2?newName not provided}}" # run the code declaring the function again, replacing only the first occurrence of the name
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
    read -s -p "Please enter the same password again: " password2 || exit ; echo 1>&2
    if (( ${#password1} == 0 )) || [[ "$password1" != "$password2" ]] ; then printf 'Passwords empty or mismatch, aborting.\n' 1>&2 ; \exit 1 ; fi
    printf %s "$password1" || exit
)}

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
function version-gr-eq { printf '%s\n%s' "$1" "$2" | sort -C -V -r; }
function version-lt-eq { printf '%s\n%s' "$1" "$2" | sort -C -V ; }
function version-gt { ! version-gt-eq "$2" "$1" ; }
function version-lt { ! version-lt-eq "$2" "$1" ; }
