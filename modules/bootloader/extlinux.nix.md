/*

# Extlinux Bootloader

A simple bootloader for legacy-BIOS environments, like (by default) Qemu.
This uses the same implementation as `boot.loader.generic-extlinux-compatible` to generate the bootloader configuration, but then actually also installs `extlinux` itself, instead of relying on something else (like an externally installed u-boot) to read and execute the configuration.


## Issues

* Updating between package versions is not atomic (and I am not sure it can be).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, options, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) setup;
    cfg = config.boot.loader.extlinux;
    targetMount = let path = lib.findFirst (path: config.fileSystems?${path}) "/" (lib.fun.parentPaths cfg.targetDir); in config.fileSystems.${path};
    supportedFSes = [ "vfat" "ntfs" "ext2" "ext3" "ext4" "btrfs" "xfs" "ufs" ]; fsSupported = fs: builtins.elem fs supportedFSes;
in {

    options = { boot.loader.extlinux = {
        enable = lib.mkEnableOption ''
            `extlinux`, a simple bootloader for legacy-BIOS environments, like (by default) Qemu.
            This uses the same implementation as `boot.loader.generic-extlinux-compatible` to generate the bootloader configuration, but then actually also installs `extlinux` itself, instead of relying on something else (like an externally installed u-boot) to read and execute the configuration.
            Any options affecting the config file generation by `boot.loader.generic-extlinux-compatible` apply, but `boot.loader.generic-extlinux-compatible.enable` should not be set to `true`.

            Since the bootloader runs before selecting a generation or specialisation to run, all sub-options, similar to e.g. {option}`boot.loader.timeout`, apply globally to the system, from whichever configuration last applied its bootloader (e.g. by newly `nixos-rebuild switch/boot`ing it or by calling its `.../bin/switch-to-configuration switch/boot`)
        '';
        package = lib.mkOption { description = ''
            The `syslinux` package to install `extlinux` from use.
        ''; type = lib.types.package; default = pkgs.syslinux; defaultText = lib.literalExpression "pkgs.syslinux"; };
        targetDir = lib.mkOption { description = ''
            The path in whose `./extlinux` sub dir `extlinux` will be installed to. When `nixos-rebuild boot/switch` gets called, this or a parent path needs to be mounted from {option}`.targetPart`.
        ''; type = lib.types.strMatching ''^/.*[^/]$''; default = "/boot"; };
        targetPart = lib.mkOption { description = ''
            The `/dev/disk/by-{id,label,partlabel,partuuid,uuid}/*` path of the *disk partition* holding the filesystem that `extlinux` is installed to. This must be formatted with a filesystem that `extlinux` supports and mounted as (a parent of) {option}`.targetDir`. The disk on which the partition lies will have the bootloader section of its MBR replaced by `extlinux`'s.
        ''; type = lib.types.strMatching ''^/.*[^/]$''; default = targetMount.device; };
        allowInstableTargetPart = lib.mkOption { internal = true; type = lib.types.bool; };
        showUI = (lib.mkEnableOption ''
            a simple graphical user interface to select the configuration to start during early boot
        '') // { default = true; example = false; };
    }; };

    config = let

        generic-extlinux-compatible = "${inputs.nixpkgs}/nixos/modules/system/boot/loader/generic-extlinux-compatible";
        extlinux-conf-builder = (import generic-extlinux-compatible { inherit config pkgs lib; }).config.content.system.build.installBootLoader;

        esc = lib.escapeShellArg;

    in lib.mkMerge [ (lib.mkIf cfg.enable {

        assertions = [ {
            assertion = cfg.allowInstableTargetPart || (builtins.match ''^/dev/disk/by-(id|label|partlabel|partuuid|uuid)/.*[^/]$'' cfg.targetPart) != null;
            message = ''
                `config.boot.loader.extlinux.targetPart` is set to `${cfg.targetPart}`, which is not a stable path in `/dev/disk/by-{id,label,partlabel,partuuid,uuid}/`. Not using a unique identifier (or even using a path that can unexpectedly change) is very risky.
            '';
        } {
            assertion = fsSupported targetMount.fsType;
            message = ''
                `config.boot.loader.extlinux.targetPart`'s closest mount (`${targetMount.mountPoint}`) is of type `${targetMount.fsType}`, which is not one of extlinux's supported types (${lib.concatStringsSep ", " supportedFSes}).
            '';
        } ];

        ${setup}.bootpart = { enable = lib.mkDefault true; mountpoint = lib.mkDefault cfg.targetDir; };
        boot.loader.extlinux.allowInstableTargetPart = lib.mkForce false;

        system.boot.loader.id = "extlinux";
        system.build.installBootLoader = "${pkgs.writeShellScript "install-extlinux.sh" ''
            if [[ ! ''${1:-} || $1 != /nix/store/* ]] ; then echo "Usage: ${builtins.placeholder "out"} TOPLEVEL_PATH" 1>&2 ; exit 1 ; fi
            export PATH=${lib.makeBinPath pkgs.stdenvNoCC.initialPath}
            ${extlinux-conf-builder} "$1" -d ${esc cfg.targetDir}

            partition=${esc cfg.targetPart}
            diskDev=/dev/$( basename "$( readlink -f /sys/class/block/"$( basename "$( realpath "$partition" )" )"/.. )" ) || exit

            if [[ $( cat ${esc cfg.targetDir}/extlinux/installedVersion 2>/dev/null || true ) != ${esc cfg.package} ]] ; then
                if ! output=$( ${esc cfg.package}/bin/extlinux --install --heads=64 --sectors=32 ${esc cfg.targetDir}/extlinux 2>&1 ) ; then
                    printf '%s\n' "$output" 1>&2 ; exit 1
                fi
                printf '%s\n' ${esc cfg.package} >${esc cfg.targetDir}/extlinux/installedVersion
            fi
            if ! ${pkgs.diffutils}/bin/cmp --quiet --bytes=440 $diskDev ${esc cfg.package}/share/syslinux/mbr.bin ; then
                dd bs=440 conv=notrunc count=1 if=${esc cfg.package}/share/syslinux/mbr.bin of=$diskDev status=none || exit
            fi

            if [[ ${toString cfg.showUI} ]] ; then # showUI
                for lib in libutil menu ; do
                    if ! ${pkgs.diffutils}/bin/cmp --quiet ${esc cfg.targetDir}/extlinux/$lib.c32 ${esc cfg.package}/share/syslinux/$lib.c32 ; then
                        cp ${esc cfg.package}/share/syslinux/$lib.c32 ${esc cfg.targetDir}/extlinux/$lib.c32
                    fi
                done
                if ! ${pkgs.gnugrep}/bin/grep -qP '^UI ' ${esc cfg.targetDir}/extlinux/extlinux.conf ; then # `extlinux-conf-builder` above would have recreated this, so the check should always be true
                    ${pkgs.gnused}/bin/sed -i 's/^TIMEOUT /UI menu.c32\nTIMEOUT /' ${esc cfg.targetDir}/extlinux/extlinux.conf
                fi
            else
                : # delete library files?
            fi
        ''}";

        boot.loader.grub.enable = false;

    }) (

        (lib.mkIf (options.virtualisation?useDefaultFilesystems) { # (»nixos/modules/virtualisation/qemu-vm.nix« is imported, i.e. we are building a "vmVariant")
            boot.loader.extlinux = {
                enable = lib.mkIf config.virtualisation.useDefaultFilesystems (lib.mkVMOverride false);
                allowInstableTargetPart = lib.mkVMOverride true; # (»/dev/sdX« etc in the VM are stable (if the VM is invoked the same way))
            };
        })

    ) ];
}
