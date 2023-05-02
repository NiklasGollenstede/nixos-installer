/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, options, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.base;
    outputName = specialArgs.outputName or null;
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "The system's build inputs, to be included in the flake registry, and on the »NIX_PATH« entry, such that they are available for self-rebuilds and e.g. as »pkgs« on the CLI."; type = lib.types.attrsOf lib.types.anything; apply = lib.filterAttrs (k: v: v != null); default = { }; };
        panic_on_fail = lib.mkEnableOption "Kernel parameter »boot.panic_on_fail«" // { default = true; example = false; }; # It's stupidly hard to remove items from lists ...
        autoUpgrade = lib.mkEnableOption "automatic NixOS updates and garbage collection" // { default = outputName != null && cfg.includeInputs?self.nixosConfigurations.${outputName}; defaultText = lib.literalExpression "config.${prefix}.base.includeInputs?self.nixosConfigurations.\${outputName}"; example = false; };
        bashInit = lib.mkEnableOption "pretty defaults for interactive bash shells" // { default = true; example = false; };
    }; };

    imports = lib.optional ((builtins.substring 0 5 inputs.nixpkgs.lib.version) <= "22.05") (lib.wip.overrideNixpkgsModule "misc/extra-arguments.nix" { } (old: { config._module.args.utils = old._module.args.utils // {
        escapeSystemdPath = s: let n = builtins.replaceStrings [ "/" "-" " " ] [ "-" "\\x2d" "\\x20" ] (lib.removePrefix "/" s); in if lib.hasPrefix "." n then "\\x2e" (lib.substring 1 (lib.stringLength (n - 1)) n) else n; # (a better implementation has been merged in 22.11)
    }; }));

    config = let

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)
        documentation.man.enable = lib.mkDefault config.documentation.enable;
        nix.settings.auto-optimise-store = lib.mkDefault true; # file deduplication, see https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store-optimise.html#description
        boot.loader.timeout = lib.mkDefault 1; # save 4 seconds on startup
        services.getty.helpLine = lib.mkForce "";

        system.extraSystemBuilderCmds = (if !config.boot.initrd.enable then "" else ''
            ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
        ''); # (to deactivate this, set »system.extraSystemBuilderCmds = lib.mkAfter "rm -f $out/boot-stage-1.sh";«)

        system.activationScripts.diff-systems = { text = ''
            if [[ -e /run/current-system ]] ; then ${pkgs.nix}/bin/nix --extra-experimental-features nix-command store diff-closures /run/current-system "$systemConfig" ; fi
        ''; deps = [ "etc" ]; }; # (to deactivate this, set »system.activationScripts.diff-systems = lib.mkForce "";«)

        virtualisation = lib.wip.mapMerge (vm: { ${vm} = let
            config' = config.virtualisation.${vm};
        in {
            virtualisation.graphics = lib.mkDefault false;
            virtualisation.writableStore = lib.mkDefault false;

            # BUG(PR): When removing all device definitions, also don't use the »resumeDevice«:
            boot.resumeDevice = lib.mkIf (!config'.virtualisation?useDefaultFilesystems || config'.virtualisation.useDefaultFilesystems) (lib.mkVMOverride "");

        }; }) [ "vmVariant" "vmVariantWithBootLoader" "vmVariantExec" ];

    }) ({
        # Robustness/debugging:

        boot.kernelParams = [ "panic=10" ] ++ (lib.optional cfg.panic_on_fail "boot.panic_on_fail"); # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.


    }) (lib.mkIf (outputName != null && cfg.includeInputs?self.nixosConfigurations.${outputName}) { # non-flake

        # Importing »<nixpkgs>« as non-flake returns a lambda returning the evaluated Nix Package Collection (»pkgs«). The most accurate representation of what that should be on the target host is the »pkgs« constructed when building it:
        system.extraSystemBuilderCmds = ''
            ln -sT ${pkgs.writeText "pkgs.nix" ''
                # Provide the exact same version of (nix)pkgs on the CLI as in the NixOS-configuration (but note that this ignores the args passed to it; and it'll be a bit slower, as it partially evaluates the host's configuration):
                args: (builtins.getFlake ${builtins.toJSON cfg.includeInputs.self}).nixosConfigurations.${outputName}.pkgs
            ''} $out/pkgs # (nixpkgs with overlays)
        ''; # (use this indirection so that all open shells update automatically)

        nix.nixPath = [ "nixpkgs=/run/current-system/pkgs" ]; # this intentionally replaces the defaults: nixpkgs is here, /etc/nixos/flake.nix is implicit, channels are impure

    }) (lib.mkIf (cfg.includeInputs != { }) { # flake things

        # "input" to the system build is definitely also a nix version that works with flakes:
        nix.settings.experimental-features = [ "nix-command" "flakes" ]; # apparently, even nix 2.8 (in nixos-22.05) needs this
        environment.systemPackages = [ pkgs.git ]; # necessary as external dependency when working with flakes

        # »inputs.self« does not have a name (that is known here), so just register it as »/etc/nixos/« system config:
        environment.etc.nixos = lib.mkIf (cfg.includeInputs?self) (lib.mkDefault { source = "/run/current-system/config"; }); # (use this indirection to prevent every change in the config to necessarily also change »/etc«)
        system.extraSystemBuilderCmds = lib.mkIf (cfg.includeInputs?self) ''
            ln -sT ${cfg.includeInputs.self} $out/config # (build input for reference)
        '';

        # Add all inputs to the flake registry:
        nix.registry = lib.mapAttrs (name: input: lib.mkDefault { flake = input; }) (builtins.removeAttrs cfg.includeInputs [ "self" ]);


    }) (lib.mkIf (cfg.autoUpgrade) {

        nix.gc = { # gc everything older than 30 days, before updating
            automatic = lib.mkDefault true; # let's hold back on this for a while
            options = lib.mkDefault "--delete-older-than 30d";
            dates = lib.mkDefault "Sun *-*-* 03:15:00";
        };
        nix.settings = { keep-outputs = true; keep-derivations = true; }; # don't GC build-time dependencies

        system.autoUpgrade = {
            enable = lib.mkDefault true;
            flake = "${config.environment.etc.nixos.source}#${outputName}";
            flags = map (dep: if dep == "self" then "" else "--update-input ${dep}") (builtins.attrNames cfg.includeInputs); # there is no "--update-inputs"
            # (Since all inputs to the system flake are linked as system-level flake registry entries, even "indirect" references that don't really exist on the target can be "updated" (which keeps the same hash but changes the path to point directly to the nix store).)
            dates = "05:40"; randomizedDelaySec = "30min";
            allowReboot = lib.mkDefault false;
        };


    }) (lib.mkIf (cfg.bashInit) {
        # (almost) Free Convenience:

        environment.shellAliases = {

            "with" = pkgs.writeShellScript "with" ''
                help='Synopsys: With the Nix packages »PKGS« (as attribute path read from the imported »nixpkgs« specified on the »NIX_PATH«), run »CMD« with »ARGS«, or »bash --login« if no »CMD« is supplied. In the second form, »CMD« is the same as the last »PKGS« entry.
                Usage: with [-h] PKGS... [-- [CMD [ARGS...]]]
                       with [-h] PKGS... [. [ARGS...]]'
                pkgs=( ) ; while (( "$#" > 0 )) ; do {
                    if [[ $1 == -h ]] ; then echo "$help" ; exit 0 ; fi
                    if [[ $1 == -- ]] ; then shift ; break ; fi
                    if [[ $1 == . ]] ; then
                        shift ; (( ''${#pkgs[@]} == 0 )) || set -- "''${pkgs[-1]}" "$@" ; break
                    fi
                    pkgs+=( "$1" )
                } ; shift ; done
                if (( ''${#pkgs[@]} == 0 )) ; then echo "$help" 1>&2 ; exit 1 ; fi
                if (( "$#" == 0 )) ; then set -- bash --login ; fi
                nix-shell --run "$( printf ' %q' "$@" )" -p "''${pkgs[@]}"
                #function run { bash -xc "$( printf ' %q' "$@" )" ; }
            ''; # »with« doesn't seem to be a common linux command yet, and it makes sense here: with package(s) => do stuff

            ls = "ls --color=auto"; # (default)
            l  = "ls -alhF"; # (added F)
            ll = "ls -alF"; # (added aF)
            lt = "tree -a -p -g -u -s -D -F --timefmt '%Y-%m-%d %H:%M:%S'"; # ll like tree
            lp = pkgs.writeShellScript "lp" ''abs="$(cd "$(dirname "$1")" ; pwd)"/"$(basename "$1")" ; ${pkgs.util-linux}/bin/namei -lx "$abs"''; # similar to »ll -d« on all path element from »$1« to »/«

            ips = "ip -c -br addr"; # colorized listing of all interface's IPs
            mounts = pkgs.writeShellScript "mounts" ''${pkgs.util-linux}/bin/mount | ${pkgs.gnugrep}/bin/grep -vPe '/.zfs/snapshot/| on /var/lib/docker/|^/var/lib/snapd/snaps/' | LC_ALL=C ${pkgs.coreutils}/bin/sort -k3 | ${pkgs.util-linux}/bin/column -t -N Device/Source,on,Mountpoint,type,Type,Options -H on,type -W Device/Source,Mountpoint,Options''; # the output of »mount«, cleaned up and formatted as a sorted table

            netns-exec = pkgs.writeShellScript "netns-exec" ''ns=$1 ; shift ; /run/wrappers/bin/firejail --noprofile --quiet --netns="$ns" -- "$@"''; # execute a command in a different netns (like »ip netns exec«), without requiring root permissions (but does require »config.programs.firejail.enable=true«)

            nixos-list-generations = "nix-env --list-generations --profile /nix/var/nix/profiles/system";

            sc  = "systemctl";
            scs = "systemctl status";
            scc = "systemctl cat";
            scu = "systemctl start"; # up
            scd = "systemctl stop"; # down
            scr = "systemctl restart";
            scf = "systemctl list-units --failed";
            scj = "journalctl -b -f -u";

        };

        programs.bash.promptInit = ''
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

        environment.interactiveShellInit = lib.mkBefore ''
            # In RePl mode: remove duplicates from history; don't save commands with a leading space.
            HISTCONTROL=ignoredups:ignorespace

            # For shells bound to serial interfaces (which can't detect the size of the screen on the other end), default to a more reasonable screen size than 24x80 blocks/chars:
            if [[ "$(realpath /dev/stdin)" != /dev/tty[1-8] && $LINES == 24 && $COLUMNS == 80 ]] ; then
                stty rows 34 cols 145 # Fairly large font on 1080p. (Setting this too large for the screen warps the output really badly.)
            fi
        '';
    }) (lib.mkIf (cfg.bashInit) { # other »interactiveShellInit« (and »shellAliases«) would go in here, being able to overwrite stuff from above, but still also being included in the alias completion below
        environment.interactiveShellInit = lib.mkAfter ''
            # enable completion for aliases
            source ${ pkgs.fetchFromGitHub {
                owner = "cykerway"; repo = "complete-alias";
                rev = "4fcd018faa9413e60ee4ec9f48ebeac933c8c372"; # v1.18 (2021-07-17)
                sha256 = "sha256-fZisrhdu049rCQ5Q90sFWFo8GS/PRgS29B1eG8dqlaI=";
            } }/complete_alias
            complete -F _complete_alias "''${!BASH_ALIASES[@]}"
        '';

    }) ]);

}
