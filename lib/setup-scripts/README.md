
# Host Setup Scripts

This is a library of bash functions, mostly for NixOS system installation.

The (paths to these) scripts are meant to be (and are by default when importing [`../../modules/installer.nix.md`](../../modules/installer.nix.md)) set as `config.installer.scripts.*`.
[`mkSystemsFlake`](../nixos.nix#mkSystemsFlake) then makes their functions available in the per-host `devShells`/`apps`.
Host-specific nix variables are available to the bash functions as `@{...}` through [`substituteImplicit`](https://github.com/NiklasGollenstede/nix-functions/blob/master/lib/scripts.nix#substituteImplicit) with the respective host as root context.
Any script passed later in `scripts` [can override](../../example/lib/install.sh.md#implementation) the functions of these (earlier) default scripts, e.g.:
```nix
{ config.installer.scripts.override = { path = .../override.sh; order = 1500; }; }
```

See `nix run .#$HOST -- --help` to see how to use the result.


## Development Notes

* The functions are designed to be (and by default are) executed with the bash options `pipefail` and `nounset` (`-u`) set.
* When the functions are executed, `generic-arg-parse` has already been called on the CLI arguments, and the parsed result can be accessed as `"${args[<name>]:-}"` for named arguments and `"${argv[<index>]}"` for positional arguments (except the first one, which has been removed and used as the command or name of the entry function to run).
* When adding functions that are meant to be called as top-level `COMMAND`s, make sure to document them by calling `declare-command`. See esp. [`maintenance.sh`](./maintenance.sh) for examples. Similarly, use `declare-flag` to add new flags to the `--help` output.
* Do not use `set -e`. It has some unexpected and unpredictable behavior, and *does not* actually provide the expected semantic of "exit the shell if a command fails (exits != 0)". For example, the internal exit behavior of commands in a function depends on *how the function is called*.
* If the `--debug` flag is passed, then `return` and `exit` are aliased to open a shell when `$?` is not zero. This effectively turns any `|| return` / `|| exit` into break-on-error point.
    * The aliasing does not work if an explicit code is provided to `return` or `exit`. In these cases, or where the breakpoint behavior is not desired, use `\return` or `\exit` (since the `\` suppresses the alias expansion).
    * For/in loops, do not write to / `read` from stdin/fd1, which conflicts with the `return`/`exit` aliasing. Instead use a different file descriptor, e.g.: `while read -u3 a b c ; do ... done 3< <( LC_ALL=C sort ... )`.
    * Similarly in functions that expect stdin data, read all of it before using the first `|| return`.
* `@{native}` is an instance of `nixpkgs` for the calling system (not the target system) with the overlays (implicitly or explicitly) passed to `mkSystemsFlake` applied, but without other `nixpkgs.overlays` set by the system configuration itself.
