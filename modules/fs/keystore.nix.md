/*

# Boot Key Store

This module does two related things:
* it provides the specification for encryption keys to be generated during system installation, which are then (automatically) used by the [setup scripts](../../lib/setup-scripts/README.md) for various pieces of file system encryption,
* and it configures a `keystore` LUKS device to be opened (according to the keys specified for it) in the initramfs boot stage to use those keys to unlock other encrypted file systems.

Keys can always be specified, and the installer may decide to use the setup script functions populating the keystore or not.
The default functions in [`lib/setup-scripts`](../../lib/setup-scripts/README.md) do populating the keystore, and then use the keys according to the description below.

What keys are used for is derived from the attribute name in the `.keys` specification, which (plus a `.key` suffix) also becomes their storage path in the keystore:
* Keys in `luks/` are used for LUKS devices, where the second path label is both the target device name and source device GPT partition label, and the third and final label is the LUKS key slot (`0` is required to be specified, `1` to `7` are optional).
* Keys in `zfs/` are used for ZFS datasets, where the further path is that of the dataset. Datasets implicitly inherit their parent's encryption by default. An empty key (created by method `unencrypted`) explicitly disables encryption on a dataset. Other keys are by default used with `keyformat=hex` and must thus be exactly 64 (lowercase) hex digits.
* Keys in `home/` are used as composites for home directory encryption, where the second and only other path label us the user name. TODO: this is not completely implemented yet.

The attribute value in the `.keys` keys specification dictates how the key is acquired, primarily initially during installation, but (depending on the keys usage) also during boot unlocking, etc.
The format of the key specification is `method[=args]`, where `method` is the suffix of a bash function call `add-key-<method>` (the default functions are in [`add-key.sh`](../../lib/setup-scripts/add-key.sh), but others could be added to the installer), and `args` is the second argument to the respective function (often a `:` separated list of arguments, but some methods don't need any arguments at all).
Most key generation methods only make sense in some key usage contexts. A `random` key is impossible to provide to unlock the keystore (which it is stored in), but is well suited to unlock other devices (if the keystore has backups (TODO!)); conversely a USB-partition can be used to headlessly unlock the keystore, but would be redundant for any further devices, as it would also be copied in the keystore.

If the module is `enable`d, a partition and LUKS device `keystore-...` gets configured and the contents of the installation time keystore is copied to it (in its entirety, including intermediate or derived keys and those unlocking the keystore itself (TODO: this could be optimized)).
This LUKS device is then configured to be unlocked (using any ot the key methods specified for it) before anything else during boot, and closed before leaving the initramfs phase.
Any number of other devices may thus specify paths in the keystore as keylocation to be unlocked during boot without needing to prompt for further secrets, and without exposing the keys to the running system.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.fs.keystore;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    keystore = "/run/keystore-${hash}";
    keystoreKeys = lib.attrValues (lib.filterAttrs (n: v: lib.wip.startsWith "luks/keystore-${hash}/" n) cfg.keys);
in let module = {

    options.${prefix} = { fs.keystore = {
        enable = lib.mkEnableOption "the use of a keystore partition to unlock various things during early boot";
        enableLuksGeneration = (lib.mkEnableOption "the generation of a LUKS mapper configuration for each »luks/*/0« entry in ».keys«") // { default = true; example = false; };
        keys = lib.mkOption { description = "Keys declared to be generated during installation and then exist in the keystore for unlocking disks and such. See »${dirname}/keystore.nix.md« for much more information."; type = lib.types.attrsOf (lib.types.either (lib.types.nullOr lib.types.str) (lib.types.attrsOf lib.types.str)); default = { }; apply = keys: (
            lib.wip.mapMergeUnique (usage: methods: if methods == null then { } else if builtins.isString methods then { "${usage}" = methods; } else lib.wip.mapMerge (slot: method: if method == null then { } else { "${usage}/${slot}" = method; }) methods) keys
        ); };
        unlockMethods = {
            trivialHostname = lib.mkOption { description = "For headless auto boot, use »hostname« (in a file w/o newline) as trivial password/key for the keystore."; type = lib.types.bool; default = lib.elem "hostname" keystoreKeys; };
            usbPartition = lib.mkOption { type = lib.types.bool; default = (lib.elem "usb-part" keystoreKeys); };
            pinThroughYubikey = lib.mkOption { type = lib.types.bool; default = (lib.any (type: lib.wip.matches "^yubikey-pin=.*$" type) keystoreKeys); };
        };
    }; };


    config = let
    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        assertions = [ {
            assertion = cfg.keys?"luks/keystore-${hash}/0";
            message = ''At least one key (»0«) for »luks/keystore-${hash}« must be specified!'';
        } ];

        boot.initrd.luks.devices = lib.mkIf cfg.enableLuksGeneration (lib.wip.mapMerge (key: let
            label = builtins.substring 5 ((builtins.stringLength key) - 7) key;
        in { ${label} = {
            device = lib.mkDefault "/dev/disk/by-partlabel/${label}";
            keyFile = lib.mkIf (label != "keystore-${hash}") (lib.mkDefault "/run/keystore-${hash}/luks/${label}/0.key");
            allowDiscards = lib.mkDefault true; # If attackers can observe trimmed blocks, then they can probably do much worse ...
        }; }) (lib.wip.filterMatching ''^luks/.*/0$'' (lib.attrNames cfg.keys)));

        ${prefix}.fs.keystore.keys."luks/keystore-${hash}/0" = lib.mkOptionDefault "hostname";

    }) ({

        boot.initrd.supportedFilesystems = [ "vfat" ];
        #boot.supportedFilesystems = [ "vfat" ]; # TODO: this should not be necessary

        boot.initrd.luks.devices."keystore-${hash}" = {
            device = "/dev/disk/by-partlabel/keystore-${hash}";
            postOpenCommands = ''
                echo "Mounting ${keystore}"
                mkdir -p ${keystore}
                mount -o nodev,umask=0277,ro /dev/mapper/keystore-${hash} ${keystore}
            '';
            preLVM = true; # ensure the keystore is opened early (»preLVM« also seems to be pre zpool import, and it is the only option that affects the opening order)
            keyFile = lib.mkMerge [
                (lib.mkIf cfg.unlockMethods.trivialHostname "${pkgs.writeText "hostname" config.networking.hostName}")
                (lib.mkIf cfg.unlockMethods.usbPartition "/dev/disk/by-partlabel/bootkey-${hash}")
            ];
            fallbackToPassword = true; # (might as well)
            preOpenCommands = lib.mkIf cfg.unlockMethods.pinThroughYubikey verbose.doOpenWithYubikey;
        };

        # Create and populate keystore during installation:
        fileSystems.${keystore} = { fsType = "vfat"; device = "/dev/mapper/keystore-${hash}"; options = [ "ro" "noatime" "umask=0277" "noauto" ]; formatOptions = ""; };

        ${prefix} = {
            fs.disks.partitions."keystore-${hash}" = { type = "8309"; order = 1375; disk = "primary"; size = "32M"; };
            fs.disks.postFormatCommands = ''
                ( : 'Copy the live keystore to its primary persistent location:'
                    tmp=$(mktemp -d) ; mount "/dev/mapper/keystore-${hash}" $tmp ; trap "umount $tmp ; rmdir $tmp" EXIT
                    ${pkgs.rsync}/bin/rsync -a ${keystore}/ $tmp/
                )
            '';
        };

        boot.initrd.postMountCommands = ''
            ${if (lib.any (lib.wip.matches "^home/.*$") (lib.attrNames cfg.keys)) then ''
                echo "Transferring home key composites"
                # needs to be available later to unlock the home on demand
                mkdir -p /run/keys/home-composite/ ; chmod 551 /run/keys/home-composite/ ; cp -a ${keystore}/home/*.key /run/keys/home-composite/
                for name in "$(ls /run/keys/home-composite/)" ; do chown "''${name:0:(-4)}": /run/keys/home-composite/"$name" ; done
            '' else ""}

            echo "Closing ${keystore}"
            umount ${keystore} ; rmdir ${keystore}
            cryptsetup close /dev/mapper/keystore-${hash}
        '';

        boot.initrd.luks.yubikeySupport = lib.mkIf cfg.unlockMethods.pinThroughYubikey true;
        boot.initrd.extraUtilsCommands = lib.mkIf cfg.unlockMethods.pinThroughYubikey (lib.mkAfter ''
            copy_bin_and_libs ${verbose.askPassWithYubikey}/bin/cryptsetup-askpass
            sed -i "s|/bin/sh|$out/bin/sh|" "$out/bin/cryptsetup-askpass"
        '');

    }) ]);

}; verbose = rec {

    tryYubikey = ''tryYubikey () { # 1: key
        local key="$1" ; local slot
        if   [ "$(ykinfo -q -2 2>/dev/null)" = '1' ] ; then slot=2 ;
        elif [ "$(ykinfo -q -1 2>/dev/null)" = '1' ] ; then slot=1 ; fi
        if [ "$slot" ] ; then
            echo >&2 ; echo "Using slot $slot of detected Yubikey ..." >&2
            key="$(ykchalresp -$slot "$key" 2>/dev/null || true)"
            if [ "$key" ] ; then echo "Got response from Yubikey" >&2 ; fi
        fi
        printf '%s' "$key"
    }'';

    # The next tree strings are copied from https://github.com/NixOS/nixpkgs/blob/1c9b2f18ced655b19bf01ad7d5ef9497d48a32cf/nixos/modules/system/boot/luksroot.nix
    # The only modification is the addition and invocation of »tryYubikey«
    commonFunctions = ''
        die() {
            echo "$@" >&2
            exit 1
        }
        dev_exist() {
            local target="$1"
            if [ -e $target ]; then
                return 0
            else
                local uuid=$(echo -n $target | sed -e 's,UUID=\(.*\),\1,g')
                blkid --uuid $uuid >/dev/null
                return $?
            fi
        }
        wait_target() {
            local name="$1"
            local target="$2"
            local secs="''${3:-10}"
            local desc="''${4:-$name $target to appear}"
            if ! dev_exist $target; then
                echo -n "Waiting $secs seconds for $desc..."
                local success=false;
                for try in $(seq $secs); do
                    echo -n "."
                    sleep 1
                    if dev_exist $target; then
                        success=true
                        break
                    fi
                done
                if [ $success == true ]; then
                    echo " - success";
                    return 0
                else
                    echo " - failure";
                    return 1
                fi
            fi
            return 0
        }
    '';
    doOpenWithYubikey = (let
        inherit (lib) optionalString;
        inherit (config.boot.initrd) luks;
        inherit (config.boot.initrd.luks.devices."keystore-${hash}") name device header keyFile keyFileSize keyFileOffset allowDiscards yubikey gpgCard fido2 fallbackToPassword;
        cs-open  = "cryptsetup luksOpen ${device} ${name} ${optionalString allowDiscards "--allow-discards"} ${optionalString (header != null) "--header=${header}"}";
    in ''
        ${tryYubikey}

        do_open_passphrase() {
            local passphrase
            while true; do
                echo -n "Passphrase for ${device}: "
                passphrase=
                while true; do
                    if [ -e /crypt-ramfs/passphrase ]; then
                        echo "reused"
                        passphrase=$(cat /crypt-ramfs/passphrase)
                        break
                    else
                        # ask cryptsetup-askpass
                        echo -n "${device}" > /crypt-ramfs/device
                        # and try reading it from /dev/console with a timeout
                        IFS= read -t 1 -r passphrase
                        if [ -n "$passphrase" ]; then
                           passphrase="$(tryYubikey "$passphrase")"
                           ${if luks.reusePassphrases then ''
                             # remember it for the next device
                             echo -n "$passphrase" > /crypt-ramfs/passphrase
                           '' else ''
                             # Don't save it to ramfs. We are very paranoid
                           ''}
                           echo
                           break
                        fi
                    fi
                done
                echo -n "Verifying passphrase for ${device}..."
                echo -n "$passphrase" | ${cs-open} --key-file=-
                if [ $? == 0 ]; then
                    echo " - success"
                    ${if luks.reusePassphrases then ''
                      # we don't rm here because we might reuse it for the next device
                    '' else ''
                      rm -f /crypt-ramfs/passphrase
                    ''}
                    break
                else
                    echo " - failure"
                    # ask for a different one
                    rm -f /crypt-ramfs/passphrase
                fi
            done
        }
    '');

    askPassWithYubikey = pkgs.writeScriptBin "cryptsetup-askpass" ''
        #!/bin/sh

        ${commonFunctions}
        ${tryYubikey}

        while true; do
            wait_target "luks" /crypt-ramfs/device 10 "LUKS to request a passphrase" || die "Passphrase is not requested now"
            device=$(cat /crypt-ramfs/device)
            echo -n "Passphrase for $device: "
            IFS= read -rs passphrase
            echo
            rm /crypt-ramfs/device
            echo -n "$(tryYubikey "$passphrase")" > /crypt-ramfs/passphrase
        done
    '';

}; in module
