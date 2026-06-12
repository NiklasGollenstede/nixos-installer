/*

# Boot Key Store

This module does two related things:
* it provides the specification for encryption keys to be generated during system installation, which are then (automatically) used by the [setup scripts](../../lib/setup-scripts/README.md) for various pieces of file system encryption,
* and it configures a `keystore` LUKS device to be opened (according to the `keys` specified for it) in the initramfs boot stage, to use those keys to unlock other encrypted file systems.

Keys can always be specified, and the installer may decide to use the setup script functions populating the keystore or not.
The default functions in [`lib/setup-scripts`](../../lib/setup-scripts/README.md) do populate the keystore, and then use the keys according to the description below.

What keys are used for is derived from the attribute name in the `.keys` specification, which (plus a `.key` suffix) also becomes their storage path in the keystore:
* Keys in `luks/` are used for LUKS devices, where the second path label is both the target device name and source device GPT partition label, and the third and final label is the LUKS key slot (`0` is required to be specified, `1` to `7` are optional).
* Keys in `zfs/` are used for ZFS datasets, where the further path is that of the dataset. Datasets implicitly inherit their parent's encryption by default. An empty key (created by method `unencrypted`) explicitly disables encryption on a dataset. Other keys are by default used with `keyformat=hex` and must thus be exactly 64 (lowercase) hex digits.
* Keys in `home/` are meant to be used as composites for home directory encryption, where the second and only other path label is the user name.

The attribute value in the `.keys` keys specification dictates how the key is acquired, primarily initially during installation, but (depending on the key's usage) also during boot unlocking, etc.
The format of the key specification is `method[=args]`, where `method` is the suffix of a bash function call `gen-key-<method>` (the default functions are in [`add-key.sh`](../../lib/setup-scripts/add-key.sh), but others could be added to the installer), and `args` is the second argument to the respective function (often a `:` separated list of arguments, but some methods don't need any arguments at all).
Most key generation methods only make sense in some key usage contexts. A `random` key is impossible to provide to unlock the keystore (which it is stored in), but is well suited to unlock other devices (if the keystore has backups); conversely a USB-partition can be used to headlessly unlock the keystore, but would be redundant for any further devices, as it would also be copied into the keystore.

If the module is `enable`d, a partition and LUKS device `keystore-...` gets configured and the contents of the installation time keystore is copied to it (in its entirety, including intermediate or derived keys and those unlocking the keystore itself).
This LUKS device is then configured to be unlocked (using any of the key methods specified for it -- by default, key slot 0 is set to the `hostname`) before anything else during boot, and closed before leaving the initramfs phase.
Any number of other devices may thus specify paths in the keystore as keylocation to be unlocked during boot without needing to prompt for further secrets, and without exposing the keys to the running system.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, utils, ... }: let lib = inputs.self.lib.__internal__; in let
    inherit (inputs.config.rename) setup installer;
    cfg = config.${setup}.keystore;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    keystore = "/run/${cfg.name}";
    keystoreKeys = lib.attrValues (lib.filterAttrs (n: v: lib.fun.startsWith "luks/${cfg.name}/" n) cfg.keys);
in {

    options = { ${setup}.keystore = {
        enable = lib.mkEnableOption "the use of a keystore partition to unlock various things during early boot";
        name = lib.mkOption { type = lib.types.str; readOnly = true; default = "keystore-${hash}"; };
        enableLuksGeneration = (lib.mkEnableOption "the generation of a LUKS mapper configuration for each »luks/*/0« entry in ».keys«") // { default = true; example = false; };
        keys = lib.mkOption { description = "Keys declared to be generated during installation and then exist in the keystore for unlocking disks and such. See »${dirname}/keystore.nix.md« for much more information."; type = lib.types.attrsOf (lib.types.either (lib.types.nullOr lib.types.str) (lib.types.attrsOf lib.types.str)); default = { }; apply = keys: (
            lib.fun.mapMergeUnique (usage: methods: if methods == null then { } else if builtins.isString methods then { "${usage}" = methods; } else lib.fun.mapMerge (slot: method: if method == null then { } else { "${usage}/${slot}" = method; }) methods) keys
        ); };
        unlockMethods = {
            trivialHostname = lib.mkOption { description = "For headless auto boot, use »hostname« (in a file w/o newline) as trivial password/key for the keystore."; type = lib.types.bool; default = lib.elem "hostname" keystoreKeys; };
            usbPartition = lib.mkOption { description = "Use (the random key stored on) a specifically named (tiny) GPT partition (usually on a USB-stick) to automatically unlock the keystore. Use »nix run .#$hostName -- add-bootkey-to-keydev $devPath« (see »${inputs.self}/lib/setup-scripts/maintenance.sh«) to cerate such a partition."; type = lib.types.bool; default = (lib.elem "usb-part" keystoreKeys); };
            pinThroughYubikey = lib.mkOption { type = lib.types.bool; default = (lib.any (type: lib.fun.matches "^yubikey-pin=.*$" type) keystoreKeys); };
        };
    }; };


    config = let
    in lib.mkIf (cfg.enable) (lib.mkMerge [ ({

        ${setup}.keystore.keys."luks/${cfg.name}/0" = lib.mkOptionDefault "hostname"; # (This is the only key that the setup scripts unconditionally require to be declared.)
        assertions = [ {
            assertion = cfg.keys?"luks/${cfg.name}/0";
            message = ''At least one key (»0«) for »luks/${cfg.name}« must be specified!'';
        } ];

    }) ({ ## Declare LUKS devices for all LUKS keys:
        ${setup}.keystore.enableLuksGeneration = lib.mkIf (config.virtualisation.useDefaultFilesystems or false) (lib.mkVMOverride false);
    }) (lib.mkIf (cfg.enableLuksGeneration) {

        boot.initrd.luks.devices = (lib.fun.mapMerge (key: let
            label = builtins.substring 5 ((builtins.stringLength key) - 7) key;
        in { ${label} = {
            device = lib.mkDefault "/dev/disk/by-partlabel/${label}";
            keyFile = lib.mkIf (label != cfg.name) (lib.mkDefault "/run/${cfg.name}/luks/${label}/0.key");
            allowDiscards = lib.mkDefault true; # If attackers can observe trimmed blocks, then they can probably do much worse ...
        }; }) (lib.fun.filterMatching ''^luks/.*/0$'' (lib.attrNames cfg.keys)));

        boot.initrd.systemd.services = lib.mkIf (config.boot.initrd.systemd.enable) (lib.fun.mapMerge (key: let
            label = builtins.substring 5 ((builtins.stringLength key) - 7) key;
        in if label == cfg.name || (!config.boot.initrd.luks.devices?${label}) then { } else { "systemd-cryptsetup@${utils.escapeSystemdPath label}" = rec {
            overrideStrategy = "asDropin"; # (could this be set via a x-systemd.after= crypttab option?)
            after = [ "systemd-cryptsetup@keystore\\x2d${hash}.service" ]; wants = after; # (this may be implicit if systemd knew about the /run/keystore-... mount point)
        }; }) (lib.fun.filterMatching ''^luks/.*/0$'' (lib.attrNames cfg.keys)));


    }) ({ ## Create and populate keystore during installation:

        fileSystems.${keystore} = { fsType = "vfat"; device = "/dev/mapper/${cfg.name}"; options = [ "ro" "nosuid" "nodev" "noexec" "noatime" "umask=0277" "noauto" ]; formatArgs = [ ]; };

        ${setup}.disks.partitions.${cfg.name} = { type = lib.mkDefault "8309"; order = lib.mkDefault 1375; disk = lib.mkDefault "primary"; size = lib.mkDefault "32M"; };
        ${installer}.commands.postFormat = ''( : 'Copy the live keystore to its primary persistent location:'
            tmp=$(mktemp -d) && ${pkgs.util-linux}/bin/mount "/dev/mapper/${cfg.name}" $tmp && trap "${pkgs.util-linux}/bin/umount $tmp && rmdir $tmp" EXIT &&
            cp --recursive --preserve=mode -T ''${args[keystore]:-${keystore}}/ $tmp/ || exit
        ) || exit'';


        ## Unlocking and closing during early boot
    }) (lib.mkIf (!(config.virtualisation.useDefaultFilesystems or false)) (let # (don't bother with any of this if »boot.initrd.luks.devices« is forced to »{ }« in »nixos/modules/virtualisation/qemu-vm.nix«)
    in lib.mkMerge [ ({

        boot.initrd.luks.devices.${cfg.name}.keyFile = lib.mkMerge [
            (lib.mkIf (cfg.unlockMethods.trivialHostname) "${pkgs.writeText "hostname" config.networking.hostName}")
            (lib.mkIf (cfg.unlockMethods.usbPartition) "/dev/disk/by-partlabel/bootkey-${hash}")
        ];
        boot.initrd.systemd.storePaths = lib.mkIf (cfg.unlockMethods.trivialHostname && config.boot.initrd.systemd.enable) [ "${pkgs.writeText "hostname" config.networking.hostName}" ];

        boot.initrd.supportedFilesystems = [ "vfat" ];

    }) (lib.mkIf (config.boot.initrd.systemd.enable) (let # Systemd initrd

        unlockWithYubikey = pkgs.writeShellScript "unlock-with-yubikey" (let
            dev = config.boot.initrd.luks.devices.${cfg.name};
        in ''
            tryYubikey () { # 1: key
                local key="$1" ; local slot
                if   [ "$( ykinfo -q -2 2>/dev/null )" = '1' ] ; then slot=2 ;
                elif [ "$( ykinfo -q -1 2>/dev/null )" = '1' ] ; then slot=1 ; fi
                if [ "$slot" ] ; then
                    echo "Using slot $slot of detected Yubikey ..." >&2
                    key="$( ykchalresp -$slot "$key" 2>/dev/null )" || true
                    if [ "$key" ] ; then echo "Got response from Yubikey" >&2 ; fi
                fi
                printf '%s' "$key"
            }
            ${lib.optionalString (dev.keyFile != null) ''
                if systemd-cryptsetup attach '${cfg.name}' '/dev/disk/by-partlabel/${cfg.name}' ${lib.escapeShellArg dev.keyFile} '${lib.optionalString dev.allowDiscards "discard,"}headless' ; then exit ; fi
                printf '%s\n\n' 'Unlocking ${cfg.name} with '${lib.escapeShellArg dev.keyFile}' failed.' >/dev/console
            ''}
            for attempt in "" 2 3 ; do (
                passphrase=$( systemd-ask-password 'Please enter passphrase for disk ${cfg.name}'"''${attempt:+ (attempt $attempt/3)}" ) || exit
                passphrase="$( tryYubikey "$passphrase" 2>/dev/console )" || exit
                systemd-cryptsetup attach '${cfg.name}' '/dev/disk/by-partlabel/${cfg.name}' <( printf %s "$passphrase" ) '${lib.optionalString dev.allowDiscards "discard,"}headless' || exit
            ) && break ; done || exit
        '');
    in {
        boot.initrd.systemd.services = {
            "systemd-cryptsetup@keystore\\x2d${hash}" = {
                overrideStrategy = "asDropin"; # i.e., these overwrite systemd's defaults:
                serviceConfig.ExecStart = lib.mkIf (cfg.unlockMethods.pinThroughYubikey) [ "" "${unlockWithYubikey}" ];
                postStart = ''
                    echo "Mounting ${keystore}"
                    mkdir -p ${keystore}
                    mount -o nodev,umask=0277,ro /dev/mapper/${cfg.name} ${keystore}
                '';
            };
            initrd-cleanup.preStart = ''
                umount ${keystore} || true
                rmdir ${keystore} || true
                systemd-cryptsetup detach ${cfg.name}
            '';
        };
        boot.initrd.luks.devices.${cfg.name}.keyFileTimeout = 10;
        boot.initrd.systemd.storePaths = lib.mkIf (cfg.unlockMethods.pinThroughYubikey) [ unlockWithYubikey ];
        boot.initrd.systemd.initrdBin = lib.mkIf (cfg.unlockMethods.pinThroughYubikey) [ pkgs.yubikey-personalization ];

    })) ])) ]);

}
