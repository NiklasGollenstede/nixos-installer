/*

# Extlinux Bootloader

A simple bootloader for legacy-BIOS environments, like (by default) Qemu.
This uses the same implementation as `boot.loader.generic-extlinux-compatible` to generate the bootloader configuration, but then actually also installs `extlinux` itself, instead of relying on something else (like an externally installed u-boot) to read and execute the configuration.


## Issues

* Updating between package versions is not atomic (and I am not sure it can be).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.bootloader.extlinux;
    targetMount = let path = lib.findFirst (path: config.fileSystems?${path}) "/" (lib.wip.parentPaths cfg.targetDir); in config.fileSystems.${path};
    supportedFSes = [ "vfat" ]; fsSupported = fs: builtins.elem fs supportedFSes;
in {

    options.${prefix} = { bootloader.extlinux = {
        enable = lib.mkEnableOption (lib.mdDoc ''
            a simple bootloader for legacy-BIOS environments, like (by default) Qemu.
            This uses the same implementation as `boot.loader.generic-extlinux-compatible` to generate the bootloader configuration, but then actually also installs `extlinux` itself, instead of relying on something else (like an externally installed u-boot) to read and execute the configuration.
            Any options affecting the config file generation by `boot.loader.generic-extlinux-compatible` apply, but `boot.loader.generic-extlinux-compatible.enable` should not be set to `true`.
        '');
        package = lib.mkOption { description = lib.mdDoc ''
            The `syslinux` package to install `extlinux` from use.
        ''; type = lib.types.package; default = pkgs.syslinux; defaultText = lib.literalExpression "pkgs.syslinux"; };
        targetDir = lib.mkOption { description = lib.mdDoc ''
            The path in whose `./extlinux` sub dir `extlinux` will be installed to. When `nixos-rebuild boot/switch` gets called, this or a parent path needs to be mounted from {option}`.targetPart`.
        ''; type = lib.types.strMatching ''^/.*[^/]$''; default = "/boot"; };
        targetPart = lib.mkOption { description = lib.mdDoc ''
            The `/dev/disk/by-{id,label,partlabel,partuuid,uuid}/*` path of the *disk partition* holding the filesystem that `extlinux` is installed to. This must be formatted with a filesystem that `extlinux` supports and mounted as (a parent of) {option}`.targetDir`. The disk on which the partition lies will have the bootloader section of its MBR replaced by `extlinux`'s.
        ''; type = lib.types.strMatching ''^/.*[^/]$''; default = targetMount.device; };
        allowInstableTargetPart = lib.mkOption { internal = true; type = lib.types.bool; };
        showUI = (lib.mkEnableOption (lib.mdDoc "a simple graphical user interface to select the configuration to start during early boot.")) // { default = true; example = false; };
    }; };

    config = let

        confFile = "/nixos/modules/system/boot/loader/generic-extlinux-compatible";
        writeConfig = (import "${inputs.nixpkgs}/${confFile}" { inherit config pkgs lib; }).config.content.system.build.installBootLoader;

        esc = lib.escapeShellArg;

    in lib.mkIf cfg.enable ({

        assertions = [ {
            assertion = cfg.allowInstableTargetPart || (builtins.match ''^/dev/disk/by-(id|label|partlabel|partuuid|uuid)/.*[^/]$'' cfg.targetPart) != null;
            message = ''`config.${prefix}.bootloader.extlinux.targetPart` is not set to a stable path in `/dev/disk/by-{id,label,partlabel,partuuid,uuid}/`. Not using a unique identifier (or even using a path that can unexpectedly change) is very risky.'';
        } {
            assertion = fsSupported targetMount.fsType;
            message = ''`config.${prefix}.bootloader.extlinux.targetPart`'s closest mount (`${targetMount.mountPoint}`) is of type `${targetMount.fsType}`, which is not one of extlinux's supported types (${lib.concatStringsSep ", " supportedFSes}).'';
        } ];

        ${prefix} = {
            fs.boot = { enable = lib.mkDefault true; mountpoint = lib.mkDefault cfg.targetDir; };
            bootloader.extlinux.allowInstableTargetPart = lib.mkForce false;
        };

        system.boot.loader.id = "extlinux";
        system.build.installBootLoader = "${pkgs.writeShellScript "install-extlinux.sh" ''
            ${writeConfig} "$1" -d ${esc cfg.targetDir}

            partition=${esc cfg.targetPart}
            diskDev=$( realpath "$partition" ) || exit ; if [[ $diskDev == /dev/sd* ]] ; then
                diskDev=$( shopt -s extglob ; echo "''${diskDev%%+([0-9])}" )
            else
                diskDev=$( shopt -s extglob ; echo "''${diskDev%%p+([0-9])}" )
            fi

            if [[ $( cat ${esc cfg.targetDir}/extlinux/installedVersion 2>/dev/null || true ) != ${esc cfg.package} ]] ; then
                ${esc cfg.package}/bin/extlinux --install ${esc cfg.targetDir}/extlinux || exit
                printf '%s\n' ${esc cfg.package} >${esc cfg.targetDir}/extlinux/installedVersion
            fi
            if ! ${pkgs.diffutils}/bin/cmp --quiet --bytes=440 $diskDev ${esc cfg.package}/share/syslinux/mbr.bin ; then
                dd bs=440 conv=notrunc count=1 if=${esc cfg.package}/share/syslinux/mbr.bin of=$diskDev status=none || exit
            fi

            if [[ '${toString cfg.showUI}' ]] ; then # showUI
                for lib in libutil menu ; do
                    if ! ${pkgs.diffutils}/bin/cmp --quiet ${esc cfg.targetDir}/extlinux/$lib.c32 ${esc cfg.package}/share/syslinux/$lib.c32 ; then
                        cp ${esc cfg.package}/share/syslinux/$lib.c32 ${esc cfg.targetDir}/extlinux/$lib.c32
                    fi
                done
                if ! ${pkgs.gnugrep}/bin/grep -qP '^UI $' ${esc cfg.targetDir}/extlinux/extlinux.conf ; then
                    ${pkgs.perl}/bin/perl -i -pe 's/TIMEOUT/UI menu.c32\nTIMEOUT/' ${esc cfg.targetDir}/extlinux/extlinux.conf
                fi
            fi
        ''}";

        boot.loader.grub.enable = false;

    });
}
