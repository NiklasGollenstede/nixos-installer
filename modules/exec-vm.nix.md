/*

# Qemu Exec VM

TBD

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: let lib = inputs.self.lib.__internal__; hostModule = { config, options, pkgs, modulesPath, noUserModules, ... }: let
    #prefix = inputs.config.prefix;
    #cfg = config.virtualisation.exec-vm;
in {

    options = { virtualisation.exec-vm = lib.mkOption {
        description = "ZFS pools created during this host's installation.";
        type = lib.fun.types.attrsOfSubmodules (subModuleArgs@{ name, ... }: { options = {
            config = lib.mkOption {
                description = lib.mdDoc ''Machine configuration to be added to the system's qemu exec VM.'';
                 inherit (noUserModules.extendModules { modules = [ "${modulesPath}/virtualisation/qemu-vm.nix" vmModule {
                    system.nixos.tags = [ "vm-${name}" ]; # tag this to make clearer what's what
                } ]; }) type;
                default = { }; visible = "shallow";
            };
            launch = lib.mkOption {
                description = "Output shell script to launch the VM to run a passed command.";
                type = lib.types.path; readOnly = true;
            };
        }; config = {
            launch = let
                cfg = subModuleArgs.config;
                pkgs = cfg.config.virtualisation.host.pkgs;
            in pkgs.writeShellScriptBin "run-${name}-vm-exec" '' # bash
                source ${lib.fun.bash.generic-arg-parse}
                generic-arg-parse "$@" ; set -- ; set -o pipefail -u #; set -x
                script=''${argv[0]:?'The first positional argument must be the script to execute in the VM'} ; argv=( "''${argv[@]:1}" )

                tmp=$( mktemp -d nix-vm.XXXXXXXXXX --tmpdir ) && trap "rm -rf '$tmp'" EXIT || exit
                mkdir -p $tmp/{xchg/args,shared} && printf '%s\n' "$script" >$tmp/xchg/args/script && chmod +x $tmp/xchg/args/script || exit
                </etc/hosts grep -oP '127.0.0.[12] (?!localhost)\K.*' >$tmp/xchg/hostname

                export TMPDIR=$tmp USE_TMPDIR=1 SHARED_DIR=''${args[shared]:-$tmp/shared}
                export QEMU_KERNEL_PARAMS="''${QEMU_KERNEL_PARAMS:-} edd=off"
                #if [[ ! ''${args[trace]:-} ]] ; then
                    QEMU_KERNEL_PARAMS+=" rd.systemd.show_status=error systemd.show_status=error"
                #fi
                export QEMU_NET_OPTS= QEMU_OPTS=

                if [[ ''${args[quiet]:-} ]] ; then
                    QEMU_KERNEL_PARAMS+=" loglevel=3 quiet"
                    #${lib.getExe cfg.config.system.build.vm} "''${argv[@]}" &> >( ${pkgs.coreutils}/bin/tr -dc '[[:print:]]\r\n\t' | {
                    #    while IFS= read line ; do if [[ $line == magic:cm4alv0wly79p6i4aq32hy36i* ]] ; then break ; fi ; done ; cat ;
                    #} ) || { e=$? ; echo "Execution of VM failed!" 1>&2 ; exit $e ; }
                fi
                ( source ${lib.getExe cfg.config.system.build.vm} "''${argv[@]}" ) || exit

                if [[ -e $tmp/xchg/exit-code ]] ; then \exit "$( cat $tmp/xchg/exit-code )" ; fi
                echo "Execution in VM failed!" 1>&2 ; \exit 1
            '';
        }; });
    }; };

}; vmModule = { config, pkgs, utils, modulesVersion, ... }: {
    _file = "${dirname}/vm-exec.nix.md#vmModule";
    imports = [ (let
        prepare = '' # bash
            # Systemd gets upset when running inside a chroot:
            #for fs in dev proc sys run/udev run/systemd ; do /bin/mkdir -p /sysroot/$fs && /bin/mount --rbind /$fs /sysroot/$fs || exit ; done
            #/bin/chroot /sysroot ${run} </dev/ttyS0 >/dev/ttyS0 2>/dev/ttyS0 || true

            # So instead move the important mount points into the initramfs:
            for fs in etc tmp/shared tmp/xchg nix/store nix/var/nix/db ; do
                /bin/mkdir -p /$fs && /bin/mount --rbind /sysroot/$fs /$fs || exit
            done
            read -r cmdline </proc/cmdline || exit ; cmdline=' '$cmdline' '
            init=''${cmdline##* init=} ; init=''${init%% *} ; system=''${init%/init}
            $system/sw/bin/ln -sfT $system /run/booted-system || exit
            $system/sw/bin/ln -sfT $system /run/current-system || exit
            export HOME=/root ; . /etc/set-environment || exit ; export BLE_DISABLED=1
            chmod 1777 /tmp
            ${config.system.activationScripts.modprobe.text or ""}

            # Set up NATed networking:
            ip addr add 10.0.2.15/24 dev eth0
            ip link set dev eth0 up
            ip route add default via 10.0.2.2 dev eth0

            #${run} &>/dev/null & runPid=$!
            #bash -i
            #wait $runPid || true
            ${run} || true
            systemctl --force --force poweroff
        '';
        run = pkgs.writeShellScript "run-as-vm-init" '' # bash
            exit=0 ; bash /tmp/xchg/args/script || exit=$?
            echo $exit >/tmp/xchg/exit-code
            sync ; sync
        '';
    in {
        boot.initrd.systemd.services.run-command = {
            wantedBy = [ "initrd-cleanup.service" ]; before = [ "initrd-cleanup.service" ];
            after = [ "initrd-root-fs.target" "initrd-fs.target" "initrd.target" ];
            unitConfig.DefaultDependencies = false;
            script = prepare;
            serviceConfig = {
                Type = "oneshot"; TimeoutSec = 0;
                StandardInput = "tty"; StandardOutput = "inherit"; StandardError = "inherit"; TTYPath = "/dev/console"; TTYReset = true; TTYVHangup = true;
            };
            unitConfig.OnFailure = [ "poweroff.target" ]; # in case of for example OOMd
        };

        # Terminal output and debugging:
        virtualisation.graphics = false;
        boot.initrd.systemd.emergencyAccess = true;
        systemd.settings.Manager.StatusUnitFormat = lib.mkDefault "name";
        boot.initrd.systemd.settings.Manager.StatusUnitFormat = lib.mkDefault "name";
        services.getty.autologinUser = "root";
        systemd.services = {
            emergency.environment = lib.mkDefault { SYSTEMD_SULOGIN_FORCE = "1"; };
            rescue.environment = lib.mkDefault { SYSTEMD_SULOGIN_FORCE = "1"; };
        };
        boot.kernelParams = [ "console=ttyS0,115200n8" ];

        # Static system for fast-ish booting:
        system.stateVersion = modulesVersion;
        boot.initrd.systemd.enable = true;
        system.nixos-init.enable = true;
        system.etc.overlay = { enable = true; mutable = false; };
        services.userborn = { enable = true; static = true; }; # NB: this works here, but is otherwise pretty bad, as uids set to null get potentially unstable values between builds
        system.switch.enable = false;
        documentation.enable = false;
        environment.etc."machine-id".text = lib.mkDefault "";
        networking.resolvconf.enable = false;
        environment.etc."resolv.conf".text = "nameserver 10.0.2.3\n";
        services.qemuGuest.enable = lib.mkForce false;
        boot.zfs.forceImportRoot = true; # (set explicitly only to suppress a warning)

        # Filesystems:
        virtualisation.writableStore = true;
        virtualisation.additionalPaths = lib.mkForce [ ]; # makes (re-)building the VM a lot faster
        boot.resumeDevice = lib.mkVMOverride "";
        virtualisation.useDefaultFilesystems = false;
        virtualisation.diskImage = null;
        virtualisation.fileSystems = {
            "/" = lib.mkForce {
                fsType = "tmpfs"; device = "tmpfs"; neededForBoot = true;
                options = [ "mode=1777" "noatime" "nosuid" "nodev" "size=50%" ];
            };
            "/nix/var/nix/.ro-db" = {
                fsType = "9p"; device = "nix-var-nix-db"; neededForBoot = true;
                options = [ "trans=virtio" "version=9p2000.L" "msize=${toString config.virtualisation.msize}" "ro" ];
            };
            "/nix/var/nix/db" = { overlay = {
                lowerdir = [ "/nix/var/nix/.ro-db" ];
                upperdir = "/nix/var/nix/.rw-db/upper";
                workdir = "/nix/var/nix/.rw-db/work";
            }; neededForBoot = true; };
        };
        virtualisation.msize = 16384; # TODO: might want to increase this
        virtualisation.memorySize = 4096; # qemu options on the CLI override this
        virtualisation.qemu.options = [ "-virtfs local,path=/nix/var/nix/db,security_model=none,mount_tag=nix-var-nix-db,readonly=on" ]; # (doing this manually to pass »readonly«, to not ever corrupt the host's Nix DBs)

        # Misc:
        virtualisation.qemu.package = lib.mkIf (!lib.systems.equals config.virtualisation.host.pkgs.stdenv.hostPlatform pkgs.stdenv.hostPlatform) config.virtualisation.host.pkgs.qemu_full;
        #virtualisation.directBoot.enable = false;
        #virtualisation.qemu.options = [
        #    "-kernel ${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}"
        #    "-initrd ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}"
        #    ''-append ${lib.escapeShellArg (lib.concatStringsSep " " config.boot.kernelParams)}' '"$QEMU_KERNEL_PARAMS"''
        #];

    }) (let # Enable binfmt in the initramfs stage:
        mkInterpreter = name: { interpreter, wrapInterpreterInShell, ... }: if wrapInterpreterInShell then pkgs.writeShellScript "${name}-interpreter" "#!${pkgs.bash}/bin/sh\nexec -- ${interpreter} \"$@\"" else interpreter;
    in {
        boot.initrd.kernelModules = [ "binfmt_misc" ];
        boot.initrd.systemd = {
            contents."/etc/binfmt.d/nixos.conf".source = config.environment.etc."binfmt.d/nixos.conf".source;
            tmpfiles.settings.binfmt = {
                "/run/binfmt".d.mode = "0755";
            } // builtins.listToAttrs (lib.mapAttrsToList (name: interpreter: {
                name = "/run/binfmt/${name}";
                value."L+".argument = interpreter;
            }) (lib.mapAttrs mkInterpreter config.boot.binfmt.registrations) );
            additionalUpstreamUnits = lib.mkIf (config.boot.binfmt.registrations != { }) [
              "proc-sys-fs-binfmt_misc.automount"
              "proc-sys-fs-binfmt_misc.mount"
              "systemd-binfmt.service"
            ];
            services.systemd-binfmt.after = lib.mkIf (config.boot.binfmt.registrations != { }) [ "systemd-tmpfiles-setup.service" ];
            storePaths = [ "${config.boot.initrd.systemd.package}/lib/systemd/systemd-binfmt" ];
        };

    }) ];

}; in hostModule
