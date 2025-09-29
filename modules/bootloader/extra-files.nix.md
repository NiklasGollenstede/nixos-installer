/*

# Extra Boot-Partition Files

This module allows copying additional files to the boot partition when installing/updating the bootloader.

There is `boot.loader.systemd-boot/grub.extraFiles`, but at least the implementations are awful (systemd's first deletes all old files, then copies them all again; grub's simply overwrites its files every time, ignoring old files).

To delete previous files, one could: have a list of old files, read that as keys of a named array, add the to-be-installed files to the list of (potential) old files, install the new files and meanwhile remove each one installed from the array, delete all files left in the array (if they exist), write (only) the installed files to the list of (next time) old files.

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) setup;
    cfg = config.boot.loader.extra-files;
    targetMount = let path = lib.findFirst (path: config.fileSystems?${path}) "/" (lib.fun.parentPaths cfg.targetDir); in config.fileSystems.${path};
    supportedFSes = [ "vfat" "ntfs" "ext2" "ext3" "ext4" "btrfs" "xfs" "ufs" ]; fsSupported = fs: builtins.elem fs supportedFSes;
in {

    options = { boot.loader.extra-files = {
        enable = lib.mkEnableOption ''
            copying of additional files to the boot partition during the system's installation and activation.
            Note that this modifies the global, non-versioned bootloader state based on the last generation(s) installed / switched to, and that it only ensures the files existence, possibly overwriting previous files, but does not delete files (left by previous generations or configurations)
        '';

        files = lib.mkOption { description = ''
            ...
        ''; example = lib.literalExpression ''
            {   "config.txt".text = lib.mkAfter "disable_splash=1";
                "start4.elf".source = "${pkgs.raspberrypifw}/share/raspberrypi/boot/start4.elf";
            }
        ''; default = { }; type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, config, ... }: { options = {
            source = lib.mkOption { description = "Source path of the file."; type = lib.types.path; };
            text = lib.mkOption { description = "Text lines of the file."; default = null; type = lib.types.nullOr lib.types.lines; };
            format = lib.mkOption { description = "Formatter to use to transform `.data` into `.text` lines (if `!= null`)."; default = null; type = lib.types.nullOr (lib.types.functionTo lib.types.str); };
            data = lib.mkOption { description = "Data to serialize to become the files `.text`. A `.format`ter must be set for the file for this to become applicable, and the data assigned must conform to the particular formatters input requirements."; type = (pkgs.formats.json { }).type; };
        }; config = {
            text = lib.mkIf (config.format != null) (config.format config.data);
        }; }))); apply = lib.filterAttrs (k: v: v != null); };

        tree = lib.mkOption { internal = true; readOnly = true; type = lib.types.package; };

        # Each bootloader seems to keep an option like this separately ...
        targetDir = lib.mkOption { description = ''
            The where the files will be installed (copied) to. This has to be mounted when `nixos-rebuild boot/switch` gets called.
        ''; type = lib.types.strMatching ''^/.*[^/]$''; default = "/boot"; };

    }; } // {

        system.build.installBootLoader = lib.mkOption { apply = old: if !cfg.enable then old else pkgs.writeShellScript "${old.name or "install-bootloader"}-extra-files" ''
            ${old} "$@" || exit
            shopt -s dotglob # for the rest of the script, have globs (*) also match hidden files
            function copy () { # 1: src, 2: dst
                cd "$1" ; for name in * ; do
                    if [[ -d "$1"/"$name" ]] ; then
                        ${pkgs.coreutils}/bin/rm "$2"/"$name" 2>/dev/null || true
                        ${pkgs.coreutils}/bin/mkdir -p "$2"/"$name" ; copy "$1"/"$name" "$2"/"$name"
                    else
                        if ! ${pkgs.diffutils}/bin/cmp --quiet "$1"/"$name" "$2"/"$name" ; then
                            ${pkgs.coreutils}/bin/cp -a "$1"/"$name" "$2"/"$name"
                        fi
                    fi
                done
            }
            copy ${cfg.tree} ${lib.escapeShellArg cfg.targetDir}
        ''; };

    };

    config = {

        # This copies referenced files to reduce the installation's closure size.
        boot.loader.extra-files.tree = lib.fun.writeTextFiles pkgs "boot-files" { checkPhase = ''
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: file: ''
                path=${lib.escapeShellArg path} ; mkdir -p "$( dirname "$path" )"
                cp -aT ${lib.escapeShellArg file.source} "$path"
            '') (lib.filterAttrs (__: _:_.text == null) cfg.files))}
        ''; } (lib.fun.catAttrSets "text" (lib.filterAttrs (__: _:_.text != null) cfg.files));

    };
}
