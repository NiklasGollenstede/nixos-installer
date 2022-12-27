/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.base;
    inputDefinesSystem = cfg.includeInputs?self && cfg.includeInputs.self?nixosConfigurations && cfg.includeInputs.self.nixosConfigurations?${name};
in {

    options.${prefix} = { base = {
        enable = lib.mkEnableOption "saner defaults";
        includeInputs = lib.mkOption { description = "The system's build inputs, to be included in the flake registry, and on the »NIX_PATH« entry, such that they are available for self-rebuilds and e.g. as »pkgs« on the CLI."; type = lib.types.attrsOf lib.types.anything; apply = lib.filterAttrs (k: v: v != null); default = { }; };
        panic_on_fail = lib.mkEnableOption "Kernel parameter »boot.panic_on_fail«" // { default = true; example = false; }; # It's stupidly hard to remove items from lists ...
        autoUpgrade = lib.mkEnableOption "automatic NixOS updates and garbage collection" // { default = inputDefinesSystem; defaultText = lib.literalExpression "config.${prefix}.base.includeInputs.self.nixosConfigurations?\${name}"; example = false; };
    }; };

    # Bugfix:
    imports = [ (lib.wip.overrideNixpkgsModule ({ inherit inputs; } // specialArgs) "misc/extra-arguments.nix" (old: { config._module.args.utils = old._module.args.utils // {
        escapeSystemdPath = s: builtins.replaceStrings [ "/" "-" " " "." ] [ "-" "\\x2d" "\\x20" "\\x2e" ] (lib.removePrefix "/" s); # BUG(PR): The original function does not escape ».«, resulting in mismatching names with units generated from paths with ».« in them (e.g. overwrites for implicit mount units).
    }; })) ];

    config = let

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        users.mutableUsers = false; users.allowNoPasswordLogin = true; # Don't babysit. Can roll back or redeploy.
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = lib.mkDefault (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)
        documentation.man.enable = lib.mkDefault config.documentation.enable;
        nix.settings.auto-optimise-store = lib.mkDefault true; # file deduplication, see https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store-optimise.html#description


    }) ({
        # Robustness/debugging:

        boot.kernelParams = [ "panic=10" ] ++ (lib.optional cfg.panic_on_fail "boot.panic_on_fail"); # Reboot on kernel panic (showing the printed messages for 10s), panic if boot fails.
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name"; # Show unit names instead of descriptions during boot.


    }) (lib.mkIf (inputDefinesSystem) { # non-flake

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
            flake = config.environment.etc.nixos.source; flags = map (dep: if dep == "self" then "" else "--update-input ${dep}") (builtins.attrNames cfg.includeInputs); # there is no "--update-inputs"?
            # (Since all inputs to the system flake are linked as system-level flake registry entries, even "indirect" references that don't really exist on the target can be "updated" (which keeps the same hash but changes the path to point directly to the nix store).)
            dates = "05:40"; randomizedDelaySec = "30min";
            allowReboot = lib.mkDefault false;
        };


    }) ({
        # Free convenience:

        environment.shellAliases = { "with" = lib.mkDefault ''nix-shell --run "bash --login" -p''; }; # »with« doesn't seem to be a common linux command yet, and it makes sense here: with $package => do stuff in shell

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
            # In RePl mode: remove duplicates from history; don't save commands with a leading space.
            HISTCONTROL=ignoredups:ignorespace

            # For shells bound to serial interfaces (which can't detect the size of the screen on the other end), default to a more reasonable screen size than 24x80 blocks/chars:
            if [[ "$(realpath /dev/stdin)" != /dev/tty[1-8] && $LINES == 24 && $COLUMNS == 80 ]] ; then
                stty rows 34 cols 145 # Fairly large font on 1080p. (Setting this too large for the screen warps the output really badly.)
            fi
        '';

        system.extraSystemBuilderCmds = (if !config.boot.initrd.enable then "" else ''
            ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
        '');

        # deactivate by setting »system.activationScripts.diff-systems = lib.mkForce "";«
        system.activationScripts.diff-systems = ''
            if [[ -e /run/current-system ]] ; then ${pkgs.nix}/bin/nix --extra-experimental-features nix-command store diff-closures /run/current-system "$systemConfig" ; fi
        '';

    }) ]);

}
