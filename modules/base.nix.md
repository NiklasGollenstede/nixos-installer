/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.base;
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "The system's build inputs, to be included in the flake registry, and on the »NIX_PATH« entry, such that they are available for self-rebuilds and e.g. as »pkgs« on the CLI."; type = lib.types.attrsOf lib.types.anything; apply = lib.filterAttrs (k: v: v != null); default = { }; };
        panic_on_fail = lib.mkEnableOption "Kernel parameter »boot.panic_on_fail«" // { default = true; }; # It's stupidly hard to remove items from lists ...
        makeNoExec = lib.mkEnableOption "(almost) all filesystems being mounted as »noexec« (and »nosuid« and »nodev«)" // { default = false; };
    }; };

    # Bugfix:
    imports = [ (lib.wip.overrideNixpkgsModule ({ inherit inputs; } // specialArgs) "misc/extra-arguments.nix" (old: { config._module.args.utils = old._module.args.utils // {
        escapeSystemdPath = s: builtins.replaceStrings [ "/" "-" " " "." ] [ "-" "\\x2d" "\\x20" "\\x2e" ] (lib.removePrefix "/" s); # The original function does not escape ».«, resulting in mismatching names with units generated from paths with ».« in them.
    }; })) ];

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        implied = true; # some mount points are implied (and forced) to be »neededForBoot« in »specialArgs.utils.pathsNeededForBoot« (this marks those here)

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)
        documentation.man.enable = lib.mkDefault config.documentation.enable;
        nix.autoOptimiseStore = true; # because why not ...


    }) (lib.mkIf cfg.makeNoExec { ## Hardening

        # This was the only "special" mount that did not have »nosuid« and »nodev« set:
        systemd.packages = [ (lib.wip.mkSystemdOverride pkgs "dev-hugepages.mount" "[Mount]\nOptions=nosuid,nodev,noexec\n") ];
        # And these were missing »noexec«:
        boot.specialFileSystems."/dev".options = [ "noexec" ];
        boot.specialFileSystems."/dev/shm".options = [ "noexec" ];
        boot.specialFileSystems."/run/keys".options = [ "noexec" ];
        # "Exceptions":
        # /dev /dev/pts need »dev«
        # /run/wrappers needs »exec« »suid«
        # /run/binfmt needs »exec«
        # /run /run/user/* may need »exec« (TODO: test)
        # The Nix build dir (default: /tmp) needs »exec« (TODO)

        # Ensure that the /nix/store is not »noexec«, even if the FS it is on is:
        boot.initrd.postMountCommands = ''
            if ! mountpoint -q $targetRoot/nix/store ; then
                mount --bind $targetRoot/nix/store $targetRoot/nix/store
            fi
            mount -o remount,exec $targetRoot/nix/store
        '';
        # Nix has no (direct) settings to change where the builders have their »/build« bound to, but many builds will need it to be »exec«:
        systemd.services.nix-daemon = { # TODO: while noexec on /tmp is the problem, neither of this solve it:
            serviceConfig.PrivateTmp = true;
            #serviceConfig.PrivateMounts = true; serviceConfig.ExecStartPre = "/run/wrappers/bin/mount -o remount,exec /tmp";
        };

        # And now make all "real" FSs »noexec« (if »wip.fs.temproot.enable = true«):
        ${prefix}.fs.temproot = let
            it = { mountOptions = { nosuid = true; noexec = true; nodev = true; }; };
        in { temp = it; local = it; remote = it; };

        nix.allowedUsers = [ "root" "@wheel" ]; # This goes hand-in-hand with setting mounts as »noexec«. Cases where a user other than root should build stuff are probably fairly rare. A "real" user might want to, but that is either already in the wheel(sudo) group, or explicitly adding that user is pretty reasonable.

        boot.postBootCommands = ''
            # Make the /nix/store non-iterable, to make it harder for unprivileged programs to search the store for programs they should not have access to:
            unshare --fork --mount --uts --mount-proc --pid -- ${pkgs.bash}/bin/bash -euc '
                mount --make-rprivate / ; mount --bind /nix/store /nix/store ; mount -o remount,rw /nix/store
                chmod -f 1771 /nix/store
                chmod -f  751 /nix/store/.links
            '
        '';


    }) ({
        # Robustness/debugging:

        boot.kernelParams = [ "panic=10" ] ++ (lib.optional cfg.panic_on_fail "boot.panic_on_fail"); # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.


    }) (let
        name = config.networking.hostName;
    in lib.mkIf (cfg.includeInputs?self && cfg.includeInputs.self?nixosConfigurations && cfg.includeInputs.self.nixosConfigurations?${name}) { # non-flake

        # Importing »<nixpkgs>« as non-flake returns a lambda returning the evaluated Nix Package Collection (»pkgs«). The most accurate representation of what that should be on the target host is the »pkgs« constructed when building it:
        system.extraSystemBuilderCmds = ''
            ln -sT ${pkgs.writeText "pkgs.nix" ''
                # Provide the exact same version of (nix)pkgs on the CLI as in the NixOS-configuration (but note that this ignores the args passed to it; and it'll be a bit slower, as it partially evaluates the host's configuration):
                args: (builtins.getFlake ${builtins.toJSON cfg.includeInputs.self}).nixosConfigurations.${name}.pkgs
            ''} $out/pkgs # (nixpkgs with overlays)
        ''; # (use this indirection so that all open shells update automatically)

        nix.nixPath = [ "nixpkgs=/run/current-system/pkgs" ]; # this intentionally replaces the defaults: nixpkgs is here, /etc/nixos/flake.nix is implicit, channels are impure

    }) (lib.mkIf (cfg.includeInputs != { }) { # flake things

        # "input" to the system build is definitely also a nix version that works with flakes:
        nix.extraOptions = "experimental-features = nix-command flakes"; # apparently, even nix 2.8 (in nixos-22.05) needs this
        environment.systemPackages = [ pkgs.git ]; # necessary as external dependency when working with flakes

        # »inputs.self« does not have a name (that is known here), so just register it as »/etc/nixos/« system config:
        environment.etc.nixos.source = lib.mkIf (cfg.includeInputs?self) (lib.mkDefault "/run/current-system/config"); # (use this indirection to prevent every change in the config to necessarily also change »/etc«)
        system.extraSystemBuilderCmds = lib.mkIf (cfg.includeInputs?self) ''
            ln -sT ${cfg.includeInputs.self} $out/config # (build input for reference)
        '';

        # Add all inputs to the flake registry:
        nix.registry = lib.mapAttrs (name: input: lib.mkDefault { flake = input; }) (builtins.removeAttrs cfg.includeInputs [ "self" ]);


    }) ({
        # Free convenience:

        environment.shellAliases = { "with" = ''nix-shell --run "bash --login" -p''; }; # »with« doesn't seem to be a common linux command yet, and it makes sense here: with $package => do stuff in shell

        programs.bash.promptInit = lib.mkDefault ''
        # Provide a nice prompt if the terminal supports it.
        if [ "''${TERM:-}" != "dumb" ] ; then
            if [[ "$UID" == '0' ]] ; then if [[ ! "''${SUDO_USER:-}" ]] ; then # direct root: red username + green hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[91m\]\u\[\e[97m\]@\[\e[92m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            else # sudo root: red username + red hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[91m\]\u\[\e[97m\]@\[\e[91m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            fi ; else # other user: green username + green hostname
                PS1='\[\e[0m\]\[\e[48;5;234m\]\[\e[96m\]$(printf "%-+ 4d" $?)\[\e[93m\][\D{%Y-%m-%d %H:%M:%S}] \[\e[92m\]\u\[\e[97m\]@\[\e[92m\]\h\[\e[97m\]:\[\e[96m\]\w'"''${TERM_RECURSION_DEPTH:+\[\e[91m\]["$TERM_RECURSION_DEPTH"]}"'\[\e[24;97m\]\$ \[\e[0m\]'
            fi
            if test "$TERM" = "xterm" ; then
                PS1="\[\033]2;\h:\u:\w\007\]$PS1"
            fi
        fi
        export TERM_RECURSION_DEPTH=$(( 1 + ''${TERM_RECURSION_DEPTH:-0} ))
        ''; # The non-interactive version of bash does not remove »\[« and »\]« from PS1, but without those the terminal gets confused about the cursor position after the prompt once one types more than a bit of text there (at least via serial or SSH).

        environment.interactiveShellInit = lib.mkDefault ''
            if [[ "$(realpath /dev/stdin)" != /dev/tty[1-8] && $LINES == 24 && $COLUMNS == 80 ]] ; then
                stty rows 34 cols 145 # Fairly large font on 1080p. Definitely a better default than 24x80.
            fi
        '';

        system.extraSystemBuilderCmds = (if !config.boot.initrd.enable then "" else ''
            ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
        '');

    }) ]);

}
