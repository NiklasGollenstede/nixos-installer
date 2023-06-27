/*

# NixOS Installer Composition

This module allows for the composition of the installer from multiple script, which can be overridden for specific projects and be adjusted per host.
`writeSystemScripts` in [`../lib/nixos.nix`](../lib/nixos.nix) wraps the result such that the commands can be called from the command line, with options, arguments, and help output.
`mkSystemsFlake` exposes the individual host's installers as flake `apps`.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) installer;
    cfg = config.${installer};
in {

    options = { ${installer} = {
        scripts = lib.mkOption {
            description = ''
                Attrset of bash scripts defining functions that do installation and maintenance operations.
                The functions should expect the bash options `pipefail` and `nounset` (`-u`) to be set.
                See »./setup-scripts/README.md« for more information.
            '';
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, config, ... }: { options = {
                name = lib.mkOption { description = "Symbolic name of the script."; type = lib.types.str; default = name; readOnly = true; };
                path = lib.mkOption { description = "Path of file for ».text« to be loaded from."; type = lib.types.nullOr lib.types.path; default = null; };
                text = lib.mkOption { description = "Script text to process."; type = lib.types.str; default = builtins.readFile config.path; };
                order = lib.mkOption { description = "Inclusion order of the scripts. Higher orders will be sourced later, and can thus overwrite earlier definitions."; type = lib.types.int; default = 1000; };
            }; })));
            apply = lib.filterAttrs (k: v: v != null);
        };
        commands = let desc = when: mounted: ''
            Bash commands that are executed during the system installation, ${when}.
            Note that these commands are executed without any further sandboxing (i.e. when not using the VM installation mode, as root on the host).
            Partitions may be used via `/dev/disk/by-partlabel/`.${lib.optionalString mounted '' The target system is mounted at `$mnt`.''}
        ''; in {
            postPartition = lib.mkOption { description = desc "after partitioning the disks" false; type = lib.types.lines; default = ""; };
            postFormat = lib.mkOption { description = desc "after formatting the partitions with filesystems" false; type = lib.types.lines; default = ""; };
            postMount = lib.mkOption { description = desc "after mounting all filesystems" true; type = lib.types.lines; default = ""; };
            preInstall = lib.mkOption { description = desc "before installing the bootloader" true; type = lib.types.lines; default = ""; };
            postInstall = lib.mkOption { description = desc "just before unmounting the new system" true; type = lib.types.lines; default = ""; };
        };
        outputName = lib.mkOption {
            description = ''The name this system is (/ should be) exported as by its defining flake (as »nixosConfigurations.''${outputName}« and »apps.*-linux.''${outputName}«).'';
            type = lib.types.nullOr lib.types.str; default = null;
        };
        build.scripts = lib.mkOption {
            type = lib.types.functionTo lib.types.str;  internal = true; readOnly = true;
            default = context: lib.fun.substituteImplicit { # This replaces the `@{}` references in the scripts with normal bash variables that hold serializations of the Nix values they refer to.
                inherit pkgs; scripts = lib.sort (a: b: a.order < b.order) (lib.attrValues cfg.scripts);
                context = { inherit config options pkgs; inherit (moduleArgs) inputs; } // context;
                # inherit (builtins) trace;
            };
        };
    }; };

    config = {
        ${installer} = {
            scripts = lib.mapAttrs (name: path: lib.mkOptionDefault { inherit path; }) (lib.self.setup-scripts);
        };
    };

}
