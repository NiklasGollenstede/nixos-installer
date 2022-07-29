dirname: inputs@{ self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
    inherit (import "${dirname}/vars.nix"    dirname inputs) mapMerge mergeAttrsUnique flipNames;
    inherit (import "${dirname}/imports.nix" dirname inputs) getModifiedPackages getNixFiles importWrapped;
    inherit (import "${dirname}/scripts.nix" dirname inputs) substituteImplicit;
    setup-scripts = (import "${dirname}/setup-scripts" "${dirname}/setup-scripts"  inputs);
    prefix = inputs.config.prefix;
in rec {

    # Simplified implementation of »flake-utils.lib.eachSystem«.
    forEachSystem = systems: do: flipNames (mapMerge (arch: { ${arch} = do arch; }) systems);

    # Sooner or later this should be implemented in nix itself, for now require »inputs.nixpkgs« and a system that can run »x86_64-linux« (native or through qemu).
    patchFlakeInputs = inputs: patches: outputs: let
        inherit ((import inputs.nixpkgs { overlays = [ ]; config = { }; system = "x86_64-linux"; }).pkgs) applyPatches fetchpatch;
    in outputs (builtins.mapAttrs (name: input: if name != "self" && patches?${name} && patches.${name} != [ ] then (let
        patched = applyPatches {
            name = "${name}-patched"; src = input;
            patches = map (patch: if patch ? url then fetchpatch patch else patch) patches.${name};
        };
        sourceInfo = (input.sourceInfo or input) // patched;
    in (
        # sourceInfo = { lastModified; narHash; rev; lastModifiedDate; outPath; shortRev; }
        # A non-flake has only the attrs of »sourceInfo«.
        # A flake has »{ inputs; outputs; sourceInfo; } // outputs // sourceInfo«, where »inputs« is what's passed to the outputs function without »self«, and »outputs« is the result of calling the outputs function. Don't know the merge priority.
        if (!input?sourceInfo) then sourceInfo else (let
            outputs = (import "${patched.outPath}/flake.nix").outputs ({ self = sourceInfo // outputs; } // input.inputs);
        in { inherit (input) inputs; inherit outputs; inherit sourceInfo; } // outputs // sourceInfo)
    )) else input) inputs);

    # Generates implicit flake outputs by importing conventional paths in the local repo. E.g.:
    # outputs = inputs@{ self, nixpkgs, wiplib, ... }: wiplib.lib.wip.importRepo inputs ./. (repo@{ overlays, lib, ... }: let ... in [ repo ... ])
    importRepo = inputs: repoPath': outputs: let
        repoPath = builtins.path { path = repoPath'; name = "source"; }; # referring to the current flake directory as »./.« is quite intuitive (and »inputs.self.outPath« causes infinite recursion), but without this it adds another hash to the path (because it copies it)
    in let result = (outputs (
        (let it                = importWrapped inputs "${repoPath}/lib";      in if it.exists then rec {
            lib           = it.result;
        } else { }) // (let it = importWrapped inputs "${repoPath}/overlays"; in if it.exists then rec {
            overlays      = it.result;
            overlay       = final: prev: builtins.foldl' (prev: overlay: prev // (overlay final prev)) prev (builtins.attrValues overlays);
        } else { }) // (let it = importWrapped inputs "${repoPath}/modules";  in if it.exists then rec {
            nixosModules  = it.result;
            nixosModule   = { imports = builtins.attrValues nixosModules; };
        } else { })
    )); in if (builtins.isList result) then mergeOutputs result else result;

    # Combines »patchFlakeInputs« and »importRepo« in a single call. E.g.:
    # outputs = inputs: let patches = {
    #     nixpkgs = [
    #         # remote: { url = "https://github.com/NixOS/nixpkgs/pull/###.diff"; sha256 = inputs.nixpkgs.lib.fakeSha256; }
    #         # local: ./overlays/patches/nixpkgs-###.patch # (use long native path to having the path change if any of the other files in ./. change)
    #     ]; # ...
    # }; in inputs.wiplib.lib.wip.patchFlakeInputsAndImportRepo inputs patches ./. (inputs@{ self, nixpkgs, ... }: repo@{ nixosModules, overlays, lib, ... }: let ... in [ repo ... ])
    patchFlakeInputsAndImportRepo = inputs: patches: repoPath: outputs: (
        patchFlakeInputs inputs patches (inputs: importRepo inputs repoPath (outputs inputs))
    );

    # Merges a list of flake output attribute sets.
    mergeOutputs = outputList: lib.zipAttrsWith (type: values: (
        if ((lib.length values) == 1) then (lib.head values)
        else if (lib.all lib.isAttrs values) then (lib.zipAttrsWith (system: values: mergeAttrsUnique values) values)
        else throw "Outputs.${type} has multiple values which are not all attribute sets, can't merge."
    )) outputList;

    # Given a path to a host config file, returns some properties defined in its first inline module (to be used where accessing them via »nodes.${name}.config...« isn't possible).
    getSystemPreface = inputs: entryPath: args: let
        imported = (importWrapped inputs entryPath).required ({ config = null; pkgs = null; lib = null; name = null; nodes = null; } // args);
        module = builtins.elemAt imported.imports 0; props = module.${prefix}.preface;
    in if (
        imported?imports && (builtins.isList imported.imports) && (imported.imports != [ ]) && module?${prefix} && module.${prefix}?preface && props?hardware
    ) then (props) else throw "File ${entryPath} must fulfill the structure: dirname: inputs: { ... }: { imports = [ { ${prefix}.preface = { hardware = str; ... } } ]; }";

    # Builds the System Configuration for a single host. Since each host depends on the context of all other host (in the same "network"), this is essentially only callable through »mkNixosConfigurations«.
    # See »mkSystemsFlake« for documentation of the arguments.
    mkNixosConfiguration = args@{ name, entryPath, peers, inputs, overlays, modules, nixosSystem, localSystem ? null, ... }: let
        preface = (getSystemPreface inputs entryPath ({ inherit lib; } // specialArgs));
        targetSystem = "${preface.hardware}-linux"; buildSystem = if localSystem != null then localSystem else targetSystem;
        specialArgs = { # make these available in the attrSet passed to the modules
            inherit inputs; # These are global and passed by the caller of this function (or not), so avoid using these (in favor of the own flakes inputs) where possible!
        } // (args.specialArgs or { }) // {
            inherit name; nodes = peers; # NixOPS
        };
    in let system = { inherit preface; } // (nixosSystem {
        system = targetSystem;
        modules = [ (
            (importWrapped inputs entryPath).module
        ) {
            # The system architecture (often referred to as »system«).
            options.${prefix}.preface.hardware = lib.mkOption { type = lib.types.str; readOnly = true; };
        } {
            # List of host names to instantiate this host config for, instead of just for the file name.
            options.${prefix}.preface.instances = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ name ]; };
        } {
            options.${prefix}.setup.scripts = lib.mkOption {
                description = ''Attrset of bash scripts defining functions that do installation and maintenance operations. See »./setup-scripts/README.md« below for more information.'';
                type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, config, ... }: { options = {
                    name = lib.mkOption { description = "Name that this device is being referred to as in other places."; type = lib.types.str; default = name; readOnly = true; };
                    path = lib.mkOption { description = "Path of file for ».text« to be loaded from."; type = lib.types.nullOr lib.types.path; default = null; };
                    text = lib.mkOption { description = "Script text to process."; type = lib.types.str; default = builtins.readFile config.path; };
                    order = lib.mkOption { description = "Parsing order of the scripts. Higher orders will be parsed later, and can thus overwrite earlier definitions."; type = lib.types.int; default = 1000; };
                }; })));
                apply = lib.filterAttrs (k: v: v != null);
            }; config.${prefix}.setup.scripts = lib.mapAttrs (name: path: lib.mkOptionDefault { inherit path; }) (setup-scripts);
        } ({ config, pkgs, ... }: {
            options.${prefix}.setup.appliedScripts = lib.mkOption {
                type = lib.types.functionTo lib.types.str; readOnly = true;
                default = context: substituteImplicit { inherit pkgs; scripts = lib.sort (a: b: a.order < b.order) (lib.attrValues config.${prefix}.setup.scripts); context = system // context; }; # inherit (builtins) trace;
            };

        }) ({ config, ... }: {

            imports = modules; nixpkgs = { inherit overlays; }
            // (if buildSystem != targetSystem then { localSystem.system = buildSystem; crossSystem.system = targetSystem; } else { system = targetSystem; });

            networking.hostName = name;

            system.extraSystemBuilderCmds = (if !config.boot.initrd.enable then "" else ''
                ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
            '');

        }) ];
        specialArgs = specialArgs; # explicitly passing »pkgs« here breaks »config.nixpkgs.overlays«!
    }); in system;

    # Given either a list (or attr set) of »files« (paths to ».nix« or ».nix.md« files for dirs with »default.nix« files in them) or a »dir« path (and optionally a list of file names to »exclude« from it), this builds the NixOS configuration for each host (per file) in the context of all configs provided.
    # If »files« is an attr set, exactly one host with the attribute's name as hostname is built for each attribute. Otherwise the default is to build for one host per configuration file, named as the file name without extension or the sub-directory name. Setting »${prefix}.preface.instances« can override this to build the same configuration for those multiple names instead (the specific »name« is passed as additional »specialArgs« to the modules and can thus be used to adjust the config per instance).
    # All other arguments are as specified by »mkSystemsFlake« and are passed to »mkNixosConfiguration«.
    mkNixosConfigurations = args: let # { files, dir, exclude, ... }
        files = args.files or (getNixFiles args.dir (args.exclude or [ ]));
        files' = if builtins.isAttrs files then files else (builtins.listToAttrs (map (entryPath: let
            stripped = builtins.match ''^(.*)[.]nix[.]md$'' (builtins.baseNameOf entryPath);
            name = builtins.unsafeDiscardStringContext (if stripped != null then (builtins.elemAt stripped 0) else (builtins.baseNameOf entryPath));
        in { inherit name; value = entryPath; }) files));

        configs = mapMerge (name: entryPath: (let
            preface = (getSystemPreface inputs entryPath { });
        in (mapMerge (name: {
            "${name}" = mkNixosConfiguration ((
                builtins.removeAttrs args [ "files" "dir" "exclude" ]
            ) // {
                inherit name entryPath; peers = configs;
            });
        }) (if !(builtins.isAttrs files) && preface?instances then preface.instances else [ name ])))) (files');

        withId = lib.filterAttrs (name: node: node.preface?id) configs;
        ids = mapMerge (name: node: { "${toString node.preface.id}" = name; }) withId;
        duplicate = builtins.removeAttrs withId (builtins.attrValues ids);
    in if duplicate != { } then (
        throw "»${prefix}.preface.id«s are not unique! The following hosts share their IDs with some other host: ${builtins.concatStringsSep ", " (builtins.attrNames duplicate)}"
    ) else configs;

    # Builds a system of NixOS hosts and exports them plus managing functions as flake outputs.
    # All arguments are optional, as long as the default can be derived from the other arguments as passed.
    mkSystemsFlake = args@{
        # An attrset of imported Nix flakes, for example the argument(s) passed to the flake »outputs« function. All other arguments are optional (and have reasonable defaults) if this is provided and contains »self« and the standard »nixpkgs«. This is also the second argument passed to the individual host's top level config files.
        inputs ? { },
        # Arguments »{ files, dir, exclude, }« to »mkNixosConfigurations«, see there for details. May also be a list of those attrsets, in which case those multiple sets of hosts will be built separately by »mkNixosConfigurations«, allowing for separate sets of »peers« passed to »mkNixosConfiguration«. Each call will receive all other arguments, and the resulting sets of hosts will be merged.
        systems ? ({ dir = "${inputs.self}/hosts"; exclude = [ ]; }),
        # List of overlays to set as »config.nixpkgs.overlays«. Defaults to the ».overlay(s)« of all »overlayInputs«/»inputs« (incl. »inputs.self«).
        overlays ? (builtins.concatLists (map (input: if input?overlay then [ input.overlay ] else if input?overlays then builtins.attrValues input.overlays else [ ]) (builtins.attrValues overlayInputs))),
        # (Subset of) »inputs« that »overlays« will be used from. Example: »{ inherit (inputs) self flakeA flakeB; }«.
        overlayInputs ? inputs,
        # List of Modules to import for all hosts, in addition to the default ones in »nixpkgs«. The host-individual module should selectively enable these. Defaults to all »ModuleInputs«/»inputs«' ».nixosModule(s)« (including »inputs.self.nixosModule(s)«).
        modules ? (map (input: input.nixosModule or (if input?nixosModules then { imports = builtins.attrValues input.nixosModules; } else { })) (builtins.attrValues moduleInputs)),
        # (Subset of) »inputs« that »modules« will be used from. (The standard) »nixpkgs« does not export any (useful) modules, since the actual modules are included by default by »nixosSystem«.
        moduleInputs ? (builtins.removeAttrs inputs [ "nixpkgs" ]),
        # Additional arguments passed to each module evaluated for the host config (if that module is defined as a function).
        specialArgs ? { },
        # The »nixosSystem« function defined in »<nixpkgs>/flake.nix«, or equivalent.
        nixosSystem ? inputs.nixpkgs.lib.nixosSystem,
        # If provided, then cross compilation is enabled for all hosts whose target architecture is different from this. Since cross compilation currently fails for (some stuff in) NixOS, better don't set »localSystem«. Without it, building for other platforms works fine (just slowly) if »boot.binfmt.emulatedSystems« on the building system is configured for the respective target(s).
        localSystem ? null,
    ... }: let
        otherArgs = (builtins.removeAttrs args [ "systems" ]) // { inherit inputs systems overlays modules specialArgs nixosSystem localSystem; };
        nixosConfigurations = if builtins.isList systems then mergeAttrsUnique (map (systems: mkNixosConfigurations (otherArgs // systems)) systems) else mkNixosConfigurations (otherArgs // systems);
    in let outputs = {
        inherit nixosConfigurations;
    } // (forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: let
        pkgs = (import inputs.nixpkgs { inherit overlays; system = localSystem; });
        tools = lib.unique (map (p: p.outPath) (lib.filter lib.isDerivation pkgs.stdenv.allowedRequisites));
        PATH = lib.concatMapStringsSep ":" (pkg: "${pkg}/bin") tools;
    in {

        # Do per-host setup and maintenance things:
        # SYNOPSIS: nix run REPO#HOST [-- [sudo] [bash | -x [-c SCRIPT | FUNC ...ARGS]]]
        # Where »REPO« is the path to a flake repo using »mkSystemsFlake« for it's »apps« output, and »HOST« is the name of a host it defines.
        # If the first argument (after  »--«) is »sudo«, then the program will re-execute itself as root using sudo (minus that »sudo« argument).
        # If the (then) first argument is »bash«, or if there are no (more) arguments, it will execute an interactive shell with the variables and functions sourced (largely equivalent to »nix develop .#$host«).
        # »-x« as next argument runs »set -x«. If the next argument is »-c«, it will evaluate (only) the following argument as bash script, otherwise the argument will be called as command, with all following arguments as arguments tot he command.
        # Examples:
        # Install the host named »$target« to the image file »/tmp/system-$target.img«:
        # $ nix run .#$target -- install-system /tmp/system-$target.img
        # Run an interactive bash session with the setup functions in the context of the current host:
        # $ nix run /etc/nixos/#$(hostname)
        # Run an root session in the context of a different host (useful if Nix is not installed for root on the current host):
        # $ nix run /etc/nixos/#other-host -- sudo
        apps = lib.mapAttrs (name: system: { type = "app"; program = "${pkgs.writeShellScript "scripts-${name}" ''

            # if first arg is »sudo«, re-execute this script with sudo (as root)
            if [[ $1 == sudo ]] ; then shift ; exec sudo --preserve-env=SSH_AUTH_SOCK -- "$0" "$@" ; fi

            # if the (now) first arg is »bash« or there are no args, re-execute this script as bash »--init-file«, starting an interactive bash in the context of the script
            if [[ $1 == bash ]] || [[ $# == 0 && $0 == *-scripts-${name} ]] ; then
                exec ${pkgs.bashInteractive}/bin/bash --init-file <(cat << "EOS"${"\n"+''
                    # prefix the script to also include the default init files
                    ! [[ -e /etc/profile ]] || . /etc/profile
                    for file in ~/.bash_profile ~/.bash_login ~/.profile ; do
                        if [[ -r $file ]] ; then . $file ; break ; fi
                    done ; unset $file
                    # add active »hostName« to shell prompt
                    PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$}
                ''}EOS
                cat $0) -i
            fi

            # provide installer tools (native to localSystem, not targetSystem)
            hostPath=$PATH ; PATH=${PATH}

            ${system.config.${prefix}.setup.appliedScripts { native = pkgs; }}

            # either call »$1« with the remaining parameters as arguments, or if »$1« is »-c« eval »$2«.
            if [[ ''${1:-} == -x ]] ; then shift ; set -x ; fi
            if [[ ''${1:-} == -c ]] ; then eval "$2" ; else "$@" ; fi
        ''}"; }) nixosConfigurations;

        # E.g.: $ nix develop /etc/nixos/#$(hostname)
        # ... and then call any of the functions in ./utils/setup-scripts/ (in the context of »$(hostname)«, where applicable).
        # To get an equivalent root shell: $ nix run /etc/nixos/#functions-$(hostname) -- sudo bash
        devShells = lib.mapAttrs (name: system: pkgs.mkShell {
            nativeBuildInputs = tools ++ [ pkgs.nixos-install-tools ];
            shellHook = ''
                ${system.config.${prefix}.setup.appliedScripts { native = pkgs; }}
                # add active »hostName« to shell prompt
                PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$}
            '';
        }) nixosConfigurations;

        # dummy that just pulls in all system builds
        packages.all-systems = pkgs.runCommandLocal "all-systems" { } ''
            ${''
                mkdir -p $out/systems
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: system: "ln -sT ${system.config.system.build.toplevel} $out/systems/${name}") nixosConfigurations)}
            ''}
            ${''
                mkdir -p $out/scripts
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: system: "ln -sT ${outputs.apps.${localSystem}.${name}.program} $out/scripts/${name}") nixosConfigurations)}
            ''}
            ${lib.optionalString (inputs != { }) ''
                mkdir -p $out/inputs
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: { outPath, ... }: "ln -sT ${outPath} $out/inputs/${name}") inputs)}
            ''}
        '';

    })); in outputs;

}
