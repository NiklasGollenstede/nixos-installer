
##
# Utilities
##

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
