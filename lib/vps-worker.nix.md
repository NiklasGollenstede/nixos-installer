/*

# Temporary VPS Workers

This file provides a function that returns scripts and complementary config to spin up a temporary VPS worker (on Hetzner Cloud), which can be used for a job like doing a nix build, before being scraped again.

This provides a pretty cheap way to do large, automated Nix builds. Building LineageOS (via `robotnix`) costs about 0.50€ (and ~30GiB traffic to and from the device issuing the build).

This is still somewhat WIP. IO between the issuer and worker could potentially be reduced significantly, if the worker had a persistent nix store, but that is harder to set up (and potentially also relatively expensive).

For now, there is not much documentation, but here is at least a short / shortened example:
```nix
# This requires a »HCLOUD_TOKEN« either as environment variable or stored in »"$baseDir"/keys/lineage-builder.api-token«.
{ build-remote = pkgs: systems: let
    builder = lib.wip.vps-worker rec {
        name = "lineage-builder";
        inherit pkgs inputs;
        serverType = "cx41"; # "cpx51"; # "cx41" is the smallest on which this builds (8GB RAM is not enough)
        tokenCmd = ''cat "$baseDir"/keys/${name}.api-token'';
        suppressCreateEmail = false;
        nixosConfig = { };
        debug = true; ignoreKill = false;
    };
    nix = "PATH=${pkgs.openssh}/bin:$PATH ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command flakes'";

in pkgs.writeShellScriptBin "lineage-build-remote" ''
    ${lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "prepend_trap"}
    set -u ; set -x
    baseDir=$1

    # Use the remote builder for the heavy lifting:
    baseDir=$baseDir ${builder.createScript} || exit ; prepend_trap "baseDir=$baseDir ${builder.killScript}" EXIT
    ${builder.remoteStore.testCmd} || exit
    ${pkgs.push-flake}/bin/push-flake ${builder.remoteStore.urlArg} ${self} || exit

    results=$( mktemp -d ) || exit ; ${if builder.args.debug then "" else ''prepend_trap "rm -rf $results" EXIT''}
    for device in ${lib.concatStringsSep " " (lib.attrNames systems)} ; do

        ${if false then ''
            # The disadvantage of this is that it won't even reuse unchanged runtime dependencies, since they are not pushed to the builder. On  the plus side, only the original sources and the actual build output will ever touch the issuer.
            result=$( ${builder.sshCmd} -- 'nix build --no-link --print-out-paths ${self}#robotnixConfigurations.'$device'.releaseScript' ) || exit
            ${nix} build ${inputs.nixpkgs}#hello --out-link $results/$device || exit ; ln -sfT $result $results/$device || exit # hack to (at least locally) prevent the copied result to be GCed
            ${nix} copy --no-check-sigs --from ${builder.remoteStore.urlArg} $result || exit
        '' else ''
            # This should reuse runtime dependencies (which are copied to and from the issuer), but build dependencies are still lost with the worker (I think). Oddly enough, it also downloads some things from the caches to the issuer.
            ulimit -Sn "$( ulimit -Hn )" # "these 3090 derivations will be built", and Nix locally creates a lockfile for each of then (?)
            result=$results/$device
            ${nix} build --out-link $result ${lib.concatStringsSep " " builder.remoteStore.builderArgs} ${self}#robotnixConfigurations.$device.releaseScript
        ''}

        mkdir -p "$baseDir"/build/$device || exit
        ( cd "$baseDir"/build/$device ; PATH=${pkgs.gawk}/bin:$PATH $result "$baseDir"/keys/$device ) || exit
    done
''; }
```


## TODO

### Make the Worker Persistent?

* use compressed and encrypted ZFS as rootfs
    * snapshots are bing compressed, though, and quite significantly so:
        * ~65GiB ext4 data + ~55GiB swap resulted in ~38.5GiB snapshot, which took 7 minutes to capture.
        * dropping pages from the swap does not make much of a difference
        * `blkdiscard -f /dev/disk-by-partlabel/swap-...` freed 45GiB swap, remaining compressed 29GiB in 5.5 minutes
        * `fstrim -a` freed another 12GiB swap and whatever else, remaining compressed 25.5GiB in 5 minutes
    * any sort of encryption should prevent compression of used blocks
    * use `-o compress=zstd-2` (should maybe switch to that as the default compression anyway)
        * on ext4, `/.local/` had a size of 69GiB after a successful build
* suspend:
    * leave gc roots on the last build, then do gc
    * disable and discard swap
    * take a server snapshot with a fixed name
        * attach `realpath /run/current-system` as label to the snapshot
    * delete the server
* wake up:
    * restore the snapshot
    * ssh to initrd
        * create swap
        * unlock zfs
        * if the `realpath /run/current-system` is outdated, transfer the current system build (and delete the old one? do gc?)
    * boot stage 2 into the target system
* extlinux can also chain-load, so could:
    * use a super cheap cx11 server to upload a boot image to a new volume
        * this would contain pretty much a normal installation
        * the volume should be small, so the last one could be cached
    * then create the main server, restoring the snapshot if there is one, and hooking up the volume
        * if there was no snapshot, ssh into Ubuntu, install the chain-loader (using Ubuntu's /boot) pointing to the volume, reboot
            * could also completely clear out the disk, install only the bootloader, and thus create a tiny snapshot to be reused for new installs
    * booting from the volume, in the initrd:
        * if the partitioning is not correct, create partitions, filesystems, bootloader, and swap
        * copy the new system components to the persistent store
            * either by starting dropbear and waiting for the master to upload, or by unpacking it from a partition on the volume
                * the former would work well with supplying encryption keys as well
            * maybe remove the old system gc root and gc again
        * resume booting of the persistent store


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS lib:
dirname: inputs@{ self, nixpkgs, ... }: let
    inherit (self) lib;
    defaultInputs = inputs;

    ## Hetzner VPS types, as of 2023-01: »cpu« in cores, »ram« in GB, »ssd« in GB, »ph« and »pm« price in €ct per hour (o/w VAT), »pm« monthly cap in € (about 26 - 27 days).
    #  Plus .1ct/h (.6€/m) for the IPv4 (TODO: could add a flag to do IPv6 only):
    serverTypes = {
         cx11 = { cpu =  1; ram =  2; ssd =  20; ph =   .6; pm =  3.92; };
        cpx11 = { cpu =  2; ram =  2; ssd =  40; ph =   .7; pm =  4.58; };
         cx21 = { cpu =  2; ram =  4; ssd =  40; ph =   .9; pm =  5.77; };
        cpx21 = { cpu =  3; ram =  4; ssd =  80; ph =  1.3; pm =  8.39; };
         cx31 = { cpu =  2; ram =  8; ssd =  80; ph =  1.7; pm = 10.95; };
        cpx31 = { cpu =  4; ram =  8; ssd = 160; ph =  2.5; pm = 15.59; };
         cx41 = { cpu =  4; ram = 16; ssd = 160; ph =  3.3; pm = 20.11; };
        cpx41 = { cpu =  8; ram = 16; ssd = 240; ph =  4.9; pm = 29.39; };
         cx51 = { cpu =  8; ram = 32; ssd = 240; ph =  6.4; pm = 38.56; };
        cpx51 = { cpu = 16; ram = 32; ssd = 360; ph = 10.4; pm = 64.74; };
    };


in ({
    name, localName ? name,
    pkgs, # The nixpkgs instance used to build the worker management scripts.
    inputs ? defaultInputs, # The flake inputs used to evaluate the worker's config.
    inheritFrom ? null, # Optional nixOS configuration from which to inherit locale settings and the like.
    serverType ? "cx21", issuerSystem ? pkgs.system, vpsSystem ? "x86_64-linux",
    tokenFile ? null, # File containing the Hetzner Cloud API token (»HCLOUD_TOKEN«). Only relevant if neither the environment variable »HCLOUD_TOKEN« nor the »tokenCmd« argument are set.
    tokenCmd ? (if tokenFile == null then "echo 'Environment variable HCLOUD_TOKEN must be set!' 1>&2 ; false" else "cat ${lib.escapeShellArg tokenFile}"),
    suppressCreateEmail ? true, # Suppress the email upon server creation. This requires the cloud project to have an SSH key named `dummy` (with any key value).
    keysOutPath ? "/tmp/vps-worker-${localName}-keys", # TODO: assert that this does not need to be escaped
    useZfs ? true, swapPercent ? if useZfs then 20 else 50,
    nixosConfig ? { }, # Extra NixOS config to use when assembling the worker.
    debug ? false, ignoreKill ? debug,
}: let
    args = { inherit name localName pkgs inputs inheritFrom serverType issuerSystem vpsSystem tokenFile tokenCmd suppressCreateEmail keysOutPath useZfs swapPercent nixosConfig debug; };
    esc = lib.escapeShellArg;

    hash = builtins.substring 0 8 (builtins.hashString "sha256" name); dataPart = if useZfs then "rpool-${hash}" else "local-${hash}";

    workerConfig = { pkgs, config, options, ... }: { _file = "${dirname}/vps-worker.nix.md#workerConfig"; imports = let
        noFS = options.virtualisation?useDefaultFilesystems && config.virtualisation.useDefaultFilesystems;
    in [ nixosConfig ({

        system.stateVersion = builtins.substring 0 5 inputs.nixpkgs.lib.version; # really doesn't matter for these configs
        wip.preface.hardware = builtins.replaceStrings [ "-linux" ] [ "" ] vpsSystem;
        wip.hardware.hetzner-vps.enable = true; # (this is where the interesting stuff happens)
        wip.base.enable = true;

        services.openssh.enable = true;
        services.openssh.extraConfig = lib.mkOrder (-1) "Include ${builtins.toFile "user-root.conf" ''Match User root
            AuthorizedKeysFile /local/etc/ssh/loginKey.pub
        ''}";
        networking.firewall.logRefusedConnections = false; # it's super spam-my and pretty irrelevant
        documentation.nixos.enable = lib.mkDefault false; # It just takes way to long to make these, and they rebuild way too often ...
        nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
        nix.settings.experimental-features = [ "recursive-nix" "impure-derivations" ]; # might as well enable fun stuff

    }) (lib.mkIf (inheritFrom != null) {

        networking.domain = inheritFrom.networking.domain;
        time.timeZone = inheritFrom.time.timeZone;
        i18n.defaultLocale = inheritFrom.i18n.defaultLocale;

    }) (lib.mkIf (!noFS) { ## Basic FS Setup
        wip.fs.boot.enable = true;
        wip.fs.boot.size = "128M"; # will only ever store one boot configuration
        wip.fs.temproot.enable = true;
        services.logind.extraConfig = "RuntimeDirectorySize=0\nRuntimeDirectoryInodesMax=0\n"; # adjusts the size of »/run/user/X/«
        wip.fs.temproot.temp.mounts."/tmp".options = lib.mkIf (!useZfs) { size = 0; nr_inodes = 0; }; # nix build dirs get placed here, no this needs lots of space (but we have swap for that)
        wip.fs.temproot.local = { type = "bind"; bind.base = "ext4"; }; # need to use an FS that can be resized (easily)
        wip.fs.temproot.remote.type = "none"; # no need to ever back up anything
        wip.fs.disks.devices.primary.size = lib.mkDefault (if useZfs then "2G" else "3G"); # define a small-ish disk (will get expanded upon boot)
        wip.fs.temproot.swap = { asPartition = true; size = "128M"; }; # will get expanded upon boot
        wip.fs.disks.partitions."swap-${hash}" = { index = 4; order = 250; }; # move swap part to the back, so that the start of the local part does not change when expanding both (swap can simply be re-created)
        wip.fs.disks.partitions.${dataPart} = { index = 3; size = lib.mkForce "${toString ((lib.wip.parseSizeSuffix config.wip.fs.disks.devices.primary.size) / 1024 / 1024 - 512)}M"; }; # since this is no longer the last partition, it needs an explicit size
        fileSystems = lib.mkIf (!useZfs) { "/.local".autoResize = true; };
        security.pam.loginLimits = [ { domain = "*"; type = "-"; item = "nofile"; value = 1048576; } ]; # avoid "too many open files"

    }) (lib.mkIf (useZfs && !noFS) { ## ZFS
        wip.fs.temproot.local.type = lib.mkForce "zfs";
        wip.fs.zfs.datasets."rpool-${hash}".props = { compression = "zstd-2"; }; # zstd-2 => 1.95x, lz4 => 1.65x (on just the initial installation)
        wip.fs.temproot.temp.type = "zfs";
        wip.fs.zfs.datasets."rpool-${hash}/temp".props = { refreservation = lib.mkForce null; }; # (don't need that here)
        wip.fs.keystore.enable = true;
        wip.fs.keystore.keys."zfs/local" = "random";
        wip.fs.keystore.keys."luks/keystore-${hash}/0" = "hostname"; # TODO: change
        wip.fs.zfs.pools."rpool-${hash}".props = { autoexpand = "on"; };
        boot.initrd.postMountCommands = ''zpool online -e rpool-${hash} /dev/disk/by-partlabel/rpool-${hash} || fail''; # in the initrd, this does not seem to do anything
        # TODO: use `services.zfs.expandOnBoot = [ "rpool-${hash}" ]`?
        systemd.services.zpool-expand = {
            wantedBy = [ "sshd.service" ]; before = [ "sshd.service" ];
            serviceConfig.Type = "oneshot"; script = ''
                target=$( ${pkgs.util-linux}/bin/blockdev --getsize64 /dev/disk/by-partlabel/rpool-${hash} )
                while [[ $(
                    /run/booted-system/sw/bin/zpool get -Hp -o value expandsz rpool-${hash}
                ) != - ]] || (( size = $(
                    /run/booted-system/sw/bin/zpool get -Hp -o value size rpool-${hash}
                ) < ( $target * 90 / 100 ) )) ; do
                    /run/booted-system/sw/bin/zpool online -e rpool-${hash} /dev/disk/by-partlabel/rpool-${hash}
                    echo "waiting for rpool-${hash} to expand (currently ''${size:-??}/$target)" 1>&2 ; sleep 1
                done
                /run/booted-system/sw/bin/zpool list rpool-${hash} 1>&2
            '';
        };

    }) ({ ## Debugging
        wip.base.panic_on_fail = false; boot.kernelParams = [ "boot.shell_on_fail" ];# ++ [ "console=ttyS0" ];
        services.getty.autologinUser = "root"; # (better than a trivial root password)

    }) (lib.mkIf (!noFS) { ## Expand Partitions (local/rpool+swap)
        boot.initrd.postDeviceCommands = let
            noSpace = str: str; # TODO: assert that the string contains neither spaces nor single or double quotes
            createPart = disk: part: lib.concatStringsSep " " [
                "--set-alignment=${toString (if part.alignment != null then part.alignment else disk.alignment)}"
                "--new=${toString part.index}:${noSpace part.position}:+'$partSize'"
                "--partition-guid=0:${noSpace part.guid}"
                "--typecode=0:${noSpace part.type}"
                "--change-name=0:${noSpace part.name}"
            ];
            # TODO: referencing »pkgs.*« directly bloats the initrd => use extraUtils instead (or just wait for systemd in initrd)
        in ''( set -x
            diskSize=$( blockdev --getsize64 /dev/sda )
            sgdisk=' --zap-all --load-backup=${config.wip.fs.disks.partitioning}/primary.backup --move-second-header --delete ${toString config.wip.fs.disks.partitions.${dataPart}.index} --delete ${toString config.wip.fs.disks.partitions."swap-${hash}".index} '
            partSize=$(( $diskSize / 1024 * ${toString (100 - swapPercent)} / 100 ))K
            sgdisk="$sgdisk"' ${createPart config.wip.fs.disks.devices.primary config.wip.fs.disks.partitions.${dataPart}} '
            partSize= # rest
            sgdisk="$sgdisk"' ${createPart config.wip.fs.disks.devices.primary config.wip.fs.disks.partitions."swap-${hash}"} '
            ${pkgs.gptfdisk}/bin/sgdisk $sgdisk /dev/sda
            ${pkgs.parted}/bin/partprobe /dev/sda || true
            dd bs=440 conv=notrunc count=1 if=${pkgs.syslinux}/share/syslinux/mbr.bin of=/dev/sda status=none || fail

            waitDevice /dev/disk/by-partlabel/swap-${hash}
            mkswap /dev/disk/by-partlabel/swap-${hash} || fail
        )'';

    }) ]; };
    system = lib.wip.mkNixosConfiguration {
        name = name; config = workerConfig;
        preface.hardware = builtins.replaceStrings [ "-linux" ] [ "" ] vpsSystem;
        inherit inputs; localSystem = issuerSystem;
        renameOutputs = name: null; # (is not exported by the flake)
    };

    mkScript = job: cmds: pkgs.writeShellScript "${job}-vps-${localName}.sh" ''
        export HCLOUD_TOKEN ; HCLOUD_TOKEN=''${HCLOUD_TOKEN:-$( ${tokenCmd} )} || exit
        ${cmds}
    '';
    prepend_trap = lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "prepend_trap";
    hcloud = "${pkgs.hcloud}/bin/hcloud";

    ubuntu-init = pkgs.writeText "ubuntu-init" ''
        #cloud-config
        chpasswd: null
        #ssh_pwauth: false
        package_update: false
        package_upgrade: false
        ssh_authorized_keys:
            - '@sshLoginPub@'
        ssh_genkeytypes: [ ]
        ssh_keys:
            ed25519_public: '@sshSetupHostPub@'
            ed25519_private: |
        @sshSetupHostPriv_prefix8@
    '';

    installTokenCmd = ''
        ( pw= ; read -s -p "Please paste the API token for VPS worker »"${esc localName}"«: " pw ; echo ; [[ ! $pw ]] || <<<"$pw" write-secret $mnt/${esc tokenFile} )
    '';

    cerateCmd = ''
        ${prepend_trap}
        set -o pipefail -u${if debug then "x" else ""}

        keys=${keysOutPath} ; rm -rf "$keys" && mkdir -p "$keys" && chmod 750 "$keys" || exit
        for ketName in hostKey loginKey ; do
            ${pkgs.openssh}/bin/ssh-keygen -q -N "" -t ed25519 -f "$keys"/$ketName -C $ketName || exit
        done

        SUDO_USER= ${lib.wip.writeSystemScripts { inherit system pkgs; }} deploy-system-to-hetzner-vps --inspect-cmd='
            keys='$( printf %q "$keys" )' ; if [[ ''${args[no-vm]:-} ]] ; then keys=/tmp/shared ; fi # "no-vm" is set inside the VM
            mkdir -p $mnt/local/etc/ssh/ || exit
            cp -aT "$keys"/loginKey.pub  $mnt/local/etc/ssh/loginKey.pub || exit
            cp -aT "$keys"/hostKey       $mnt/local/etc/ssh/ssh_host_ed25519_key || exit
            cp -aT "$keys"/hostKey.pub   $mnt/local/etc/ssh/ssh_host_ed25519_key.pub || exit
            chown 0:0 $mnt/local/etc/ssh/* || exit
        ' ''${forceVmBuild:+--vm} --vm-shared="$keys" ${if debug then "--trace" else "--quiet"} ${lib.optionalString ignoreKill "--vps-keep-on-build-failure"} ${lib.optionalString suppressCreateEmail "--vps-suppress-create-email"} "$@" -- ${esc name} ${esc serverType} || exit # --parallel-build-deploy
        rm "$keys"/hostKey || exit # don't need this anymore

        ip=$( ${hcloud} server ip ${esc name} ) ; echo "$ip" >"$keys"/ip
        printf "%s %s\n" "$ip" "$( cat "$keys"/hostKey.pub )" >"$keys"/known_hosts
        printf '%s\n' '#!${pkgs.bash}' 'exec ${sshCmd} "$@"' >"$keys"/ssh ; chmod 555 "$keys"/ssh
        echo ${remoteStore.urlArg} >"$keys"/store ; echo ${remoteStore.builderArg} >"$keys"/builder
        printf '%s\n' '#!${pkgs.bash}' 'exec nix ${lib.concatStringsSep " " remoteStore.builderArgs} "$@"' >"$keys"/remote ; chmod 555 "$keys"/remote
    '';

    sshCmd = ''${pkgs.openssh}/bin/ssh -oUserKnownHostsFile=${keysOutPath}/known_hosts -i ${keysOutPath}/loginKey root@$( cat ${keysOutPath}/ip )'';

    killCmd = if ignoreKill then ''echo 'debug mode, keeping server '${esc name}'' else ''${hcloud} server delete ${esc name}'';

    remoteStore = rec {
        urlArg = '''ssh://root@'$( cat ${keysOutPath}/ip )'?compress=true&ssh-key='${keysOutPath}'/loginKey&base64-ssh-public-host-key='$( cat ${keysOutPath}/hostKey.pub | ${pkgs.coreutils}/bin/base64 -w0 )'';
        builderArg = (lib.concatStringsSep "' '" [
            "'ssh://root@'$( cat ${keysOutPath}/ip )'?compress=true'" # 1. URL (including the keys, the URL gets too ong to create the lockfile path)
            "i686-linux,x86_64-linux" # 2. platform type
            "${keysOutPath}/loginKey" # 3. SSH login key
            "${toString (serverTypes.${serverType} or { cpu = 4; }).cpu}" # 4. max parallel builds
            "-" # 5. speed factor (relative to other builders, so irrelevant)
            "nixos-test,benchmark,big-parallel" # 6. builder supported features (no kvm)
            "-" # 7. job required features
            ''$( cat ${keysOutPath}/hostKey.pub | ${pkgs.coreutils}/bin/base64 -w0 )'' # 8. builder host key
        ]);
        builderArgs = [
            "--max-jobs" "0" # don't build locally
            "--builders-use-substitutes" # prefer loading from public cache over loading from build issuer
            "--builders" builderArg
        ];
        testCmd = ''PATH=${pkgs.openssh}/bin:$PATH ${pkgs.nix}/bin/nix --extra-experimental-features nix-command store ping --store ${urlArg}'';
    };

    shell = pkgs.writeShellScriptBin "shell-${name}" ''
        ${createScript} "$@" || exit ; trap ${killScript} EXIT || exit

        ${pkgs.bashInteractive}/bin/bash --init-file ${pkgs.writeText "init-${name}" ''
            # Execute bash's default logic if no --init-file was provided (to inherit from a normal shell):
            ! [[ -e /etc/profile ]] || . /etc/profile
            for file in ~/.bash_profile ~/.bash_login ~/.profile ; do
                if [[ -r $file ]] ; then . $file ; break ; fi
            done ; unset $file

            ip=$( cat ${keysOutPath}/ip )
            keys=${keysOutPath}
            ssh="${sshCmd}"
            store=${remoteStore.urlArg}
            builder=${remoteStore.builderArg}
            alias remote="nix ${lib.concatStringsSep " " remoteStore.builderArgs}"
            PATH=${lib.makeBinPath [ pkgs.push-flake ]}:$PATH

            ulimit -Sn "$( ulimit -Hn )" # Chances are, we want to run really big builds. They might run out of file descriptors for local lock files.

            # »remote build ...« as non-root fails until root runs it to the point of having made some build progress?
            # This doesn't do the trick, though:
            # sudo ${pkgs.nix}/bin/nix build ${lib.concatStringsSep " " remoteStore.builderArgs} --no-link --print-out-paths --impure --expr '(import <nixpkgs> { }).writeText "rand" "'$( xxd -u -l 16 -p /dev/urandom )'"'

            PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$} # append name to the prompt
        ''} || exit
    '';

    createScript = mkScript "create" cerateCmd;
    killScript = mkScript "kill" killCmd;
in {
    inherit args installTokenCmd cerateCmd sshCmd killCmd createScript killScript shell;
    inherit remoteStore;
    inherit workerConfig system;
})
