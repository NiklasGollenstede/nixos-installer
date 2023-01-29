/*

# Qemu Exec VM

This module configures a "VM Variant" of the system that allows executing (pretty) arbitrary commands in a very lightweight qemu VM, with full access to the host's Nix store, and in the context of the systems Kernel and it's modules.

This is, for example, used to install the system to images without requiring root access (on the host).


## Usage

```bash
nix run .../nixos-config'#'nixosConfigurations.${hostName}.config.system.build.vmExec -- [--quiet] [--initrd-console] [--shared=/host/path/to/shared] "bash commands to run in VM" [-- ...extra-qemu-options]
```

* `--initrd-console` shows NixOS'es stage 1 boot output on the console (otherwise it is silenced).
* `--quiet` aims to suppress the terminal (re-)setting and all non-command output. Note that this filters the VM output.
* `--shared=` specifies an optional path to a host path that is read-write mounted at `/tmp/shared` in the VM.
* The value of the first positional argument is executed as a bash script in the VM and (if nothing else goes wrong) its exit status becomes that of the overall command.
* Any other positional arguments (that aren't parsed as named arguments, so put them after the `--` marker) are passed verbatim to the `qemu` launch command. These could for example attach disk or network devices.


## Notes

* The host's `/nix/var/nix/db` is read-only shared into the VM and then overlayed with a tmpfs. Modifying the Nix DBs on the host may have funny effects, esp. when also doing writing operations in the VM.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, modulesPath, extendModules, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.virtualisation.vmVariantExec;
in {

    options = { virtualisation.vmVariantExec = lib.mkOption {
        description = lib.mdDoc ''Machine configuration to be added to the system's qemu exec VM.'';
        inherit (extendModules { modules = [ "${modulesPath}/virtualisation/qemu-vm.nix" ]; }) type;
        default = { }; visible = "shallow";
    }; };

    config = {

        system.build.vmExec = (let vmPkgs = pkgs; in let
            name = "run-${config.system.name}-vm-exec";
            launch = "${cfg.system.build.vm}/bin/${cfg.system.build.vm.meta.mainProgram}";
            pkgs = if cfg.virtualisation?host.pkgs then cfg.virtualisation.host.pkgs else vmPkgs;
        in pkgs.runCommand "nixos-vm" {
            preferLocalBuild = true; meta.mainProgram = name;
        } ''
            mkdir -p $out/bin
            ln -s ${cfg.system.build.toplevel} $out/system
            ln -s ${pkgs.writeShellScript name ''
                ${lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "generic-arg-parse"}
                generic-arg-parse "$@" ; set -- ; set -o pipefail -u #; set -x
                script=''${argv[0]:?'The first positional argument must be the script to execute in the VM'} ; argv=( "''${argv[@]:1}" )

                tmp=$( mktemp -d nix-vm.XXXXXXXXXX --tmpdir ) && trap "rm -rf '$tmp'" EXIT || exit
                mkdir -p $tmp/{xchg,shared} && printf '%s\n' "$script" >$tmp/xchg/script && chmod +x $tmp/xchg/script || exit
                if [[ ! ''${args[initrd-console]:-} ]] ; then noConsole=1 ; fi
                if [[ ''${args[initrd-console]:-} ]] ; then touch $tmp/xchg/initrd-console ; fi
                if [[ ''${args[quiet]:-} ]] ; then touch $tmp/xchg/quiet ; fi

                ${cfg.virtualisation.qemu.package}/bin/qemu-img create -f qcow2 $tmp/dummyImage 4M &>/dev/null # do this silently

                export NIX_DISK_IMAGE=$tmp/dummyImage
                export TMPDIR=$tmp USE_TMPDIR=1 SHARED_DIR=''${args[shared]:-$tmp/shared}
                export QEMU_KERNEL_PARAMS="init=${config.system.build.toplevel}/init ''${noConsole:+console=tty1} edd=off boot.shell_on_fail"
                export QEMU_NET_OPTS= QEMU_OPTS=
                if [[ ''${args[quiet]:-} ]] ; then
                    ${launch} "''${argv[@]}" &> >( ${pkgs.coreutils}/bin/tr -dc '[[:print:]]\r\n\t' | { while IFS= read line ; do if [[ $line == magic:cm4alv0wly79p6i4aq32hy36i* ]] ; then break ; fi ; done ; cat ; } ) || { e=$? ; echo "Execution of VM failed!" 1>&2 ; exit $e ; }
                else
                    ${launch} "''${argv[@]}" || exit
                fi

                if [[ -e $tmp/xchg/exit ]] ; then \exit "$( cat $tmp/xchg/exit )" ; fi
                echo "Execution in VM failed!" 1>&2 ; \exit 1
            ''} $out/bin/${name}
        '');


    } // { virtualisation.vmVariantExec = lib.mkMerge [ ({

        # Instead of tearing down the initrd environment, adjust some mounts and run the »command« in the initrd:
        boot.initrd.postMountCommands = ''

            for fs in tmp/shared tmp/xchg nix/store.lower nix/var/nix/db.lower ; do
                mkdir -p /$fs && mount --move $targetRoot/$fs /$fs || fail
            done
            chmod 1777 /tmp

            # Nix want's to create lock files, even on read-only operations:
            mkdir -p -m 755 /nix/var/nix/db.work /nix/var/nix/db.upper /nix/var/nix/db
            mount -t overlay overlay -o lowerdir=/nix/var/nix/db.lower,workdir=/nix/var/nix/db.work,upperdir=/nix/var/nix/db.upper /nix/var/nix/db

            # Nix insists on setting the ownership of »/nix/store« to »0:30000« (if run as root(?) and it is something else, e.g. when using »nix-user-chroot«):
            mkdir -p -m 755 /nix/store.work /nix/store.upper /nix/store
            mount -t overlay overlay -o lowerdir=/nix/store.lower,workdir=/nix/store.work,upperdir=/nix/store.upper /nix/store

            # »/run/{booted,current}-system« is more for debugging than anything else, but changing »/lib/modules« makes modprobe use the full system's modules, instead of only the initrd ones:
            toplevel=$(dirname $stage2Init)
            ln -sfT $toplevel /run/current-system
            ln -sfT $toplevel /run/booted-system
            ln -sfT $toplevel/kernel-modules/lib/modules /lib/modules

            # ALso mostly dor debugging shells:
            mv /etc /etc.initrd
            mkdir -p -m 755 /etc.work /etc.upper /etc
            mount -t overlay overlay -o lowerdir=$toplevel/etc,workdir=/etc.work,upperdir=/etc.upper /etc
            ( cd /etc.initrd ; cp -a mtab udev /etc/ ) # (keep these)

            # »nix copy« complains without »nixbld« group:
            rm -f /etc/passwd /etc/group
            printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' >/etc/passwd
            printf '%s\n' 'root:x:0:' 'nixbld:x:30000:' >/etc/group
            export HOME=/root USER=root ; mkdir -p -m 700 $HOME
            PATH=/run/current-system/sw/bin ; rm -f /bin /sbin ; unset LD_LIBRARY_PATH

            console=/dev/ttyS0 ; if [[ -e /tmp/xchg/initrd-console ]] ; then console=/dev/console ; fi # (does this even make a difference?)
            if [[ -e /tmp/xchg/quiet ]] ; then printf '\n%s\n' 'magic:cm4alv0wly79p6i4aq32hy36i...' >$console ; fi

            exit=0 ; bash /tmp/xchg/script <$console >$console 2>$console || exit=$?
            echo $exit >/tmp/xchg/exit

            sync ; sync
            echo 1 > /proc/sys/kernel/sysrq
            echo o > /proc/sysrq-trigger
            sleep infinity # the VM will halt very soon
        '';
        boot.initrd.kernelModules = [ "overlay" ]; # for writable »/etc«, chown of »/nix/store« and locks in »/nix/var/nix/db«

    }) ({

        fileSystems = lib.mkVMOverride {
            "/nix/var/nix/db.lower" = {
                fsType = "9p"; device = "nix-var-nix-db"; neededForBoot = true;
                options = [ "trans=virtio" "version=9p2000.L"  "msize=65536" "ro" ];
            };
            "/nix/store".options = lib.mkAfter [ "ro" "msize=65536" ];
            "/nix/store".mountPoint = "/nix/store.lower";
        }; # mount -t 9p -o trans=virtio -o version=9p2000.L -o msize=65536 nix-var-nix-db /nix/var/nix/db
        virtualisation.qemu.options = [ "-virtfs local,path=/nix/var/nix/db,security_model=none,mount_tag=nix-var-nix-db,readonly=on" ]; # (doing this manually to pass »readonly«, to not ever corrupt the host's Nix DBs)

    }) ({

        fileSystems = lib.mkVMOverride { "/" = lib.mkForce {
            fsType = "tmpfs"; device = "tmpfs"; neededForBoot = true;
            options = [ "mode=1777" "noatime" "nosuid" "nodev" "size=50%" ];
        }; };
        virtualisation.diskSize = 4; #MB, not needed at all

        # tag this to make clearer what's what
        system.nixos.tags = [ "vmExec" ];
        system.build.isVmExec = true;

    }) ]; };
}
