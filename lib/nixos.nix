dirname: inputs@{ self, nixpkgs, functions, ...}: let
    inherit (nixpkgs) lib;
    inherit (functions.lib) forEachSystem getModulesFromInputs getNixFiles getOverlaysFromInputs importWrapped mapMerge mapMergeUnique mergeAttrsUnique; # trace;
    inherit (inputs.config.rename) installer; preface' = inputs.config.rename.preface;

    getModuleConfig = module: inputs: args: if builtins.isFunction module then (
        getModuleConfig (module args) inputs args
    ) else if (builtins.isPath module) || (builtins.isString module) then (
        getModuleConfig (importWrapped inputs module).required inputs args
    ) else if module?config then module.config else if module?_file && module?imports then (
        getModuleConfig (builtins.head module.imports) inputs args
    ) else module;

    getPreface = inputs: moduleArgs: mainModule: name: let
        args = { config = null; pkgs = null; lib = null; name = null; nodes = null; extraModules = null; } // { inherit inputs; } // moduleArgs // { name = name; };
        config = getModuleConfig mainModule inputs args;
    in config.${preface'} or { };

    getFlakeDir = input: error: if input.sourceInfo.outPath == input.sourceInfo.outPath || lib.hasPrefix input.sourceInfo.outPath input.outPath then input.outPath else throw error;

in rec {

    # Builds the System Configuration for a single host.
    mkNixosConfiguration = {
        mainModule, name,
        # See »mkSystemsFlake« for documentation of the following arguments:
        inputs ? { }, modules ? (getModulesFromInputs inputs), overlays ? (getOverlaysFromInputs inputs),
        extraModules ? [ ], moduleArgs ? { }, nixosArgs ? { },
        nixosSystem ? inputs.nixpkgs.lib.nixosSystem,
        buildPlatform ? null,
    }: nixosSystem (nixosArgs // (let args = {
        #system = null; # (This actually does nothing more than setting »config.nixpkgs.system« (which is the same as »config.nixpkgs.buildPlatform.system«) and can be null/unset here.)

        modules = (nixosArgs.modules or [ ]) ++ [ { imports = [ # Anything specific to only this evaluation of the module tree should go here.
            (let # mainModule
                module = if (builtins.isPath mainModule) || (builtins.isString mainModule) then (importWrapped inputs mainModule).module else mainModule;
                # ensure that in the main module, the "name" parameter is available during the import stage already:
                bindName2function = func: lib.setFunctionArgs (args: func (args // { inherit name; })) (builtins.removeAttrs (lib.functionArgs func) [ "name" ]);
                bindName2module = module: if lib.isFunction module then bindName2function module else if module?imports then module // { imports = map bindName2module module.imports; } else module;
            in bindName2module module)
            { _module.args.name = lib.mkOverride 0 name; } # (specialisations can somehow end up with the name »configuration«, which is very incorrect)
            { networking.hostName = name; }
            # containers may or may not want to inherit extraModules (but it is easy to add), but there is no reason not to inherit specialArgs:
            { options.containers = lib.mkOption { type = lib.types.attrsOf (lib.types.submodule (_: { config = {
                specialArgs = builtins.mapAttrs (_: lib.mkDefault) args.specialArgs; # imports = args.extraModules;
            }; })); }; }
            # `specializations` use `noUserModules`, which inherit specialArgs and extraModules, or `extendModules` inherits all modules and arguments. VM-variants also use `extendModules`.
        ]; _file = "${dirname}/nixos.nix#modules"; } ];

        extraModules = (nixosArgs.extraModules or [ ]) ++ modules ++ extraModules ++ [ { imports = [ (_: {
            # These are passed as »extraModules« module argument and can thus be reused when defining containers and such (so define as much stuff as possible here).
            # There is, unfortunately, no way to directly pass modules into all containers. Each container will need to be defined with »config.containers."${name}".config.imports = extraModules«.
            # (One could do that automatically by defining »options.security.containers = lib.mkOption { type = lib.types.submodule (cfg: { options.config = lib.mkOption { apply = _:_.extendModules { modules = extraModules; }; }); }«.)

            nixpkgs = { overlays = overlays; } // (lib.optionalAttrs (buildPlatform != null) { inherit buildPlatform; });

            _module.args = { inherit inputs; } // moduleArgs; # (pass the args here, so that they also apply to any other evaluation using »extraModules«)

            system.nixos.revision = lib.mkIf (inputs?nixpkgs.rev) inputs.nixpkgs.rev; # (evaluating the default value fails under some circumstances)

        }) ]; _file = "${dirname}/nixos.nix#mkNixosConfiguration-extraModule"; } ];

        specialArgs = (nixosArgs.specialArgs or { }) // { inherit inputs; };
        # (This is already set during module import, while »_module.args« only becomes available during module evaluation (before that, using it causes infinite recursion). Since it can't be ensured that this is set in every circumstance where »extraModules« are being used, it should generally not be used to set custom arguments.)

    }; in args));

    # Given either a list (or attr set) of »files« (paths to ».nix« or ».nix.md« files for dirs with »default.nix« files in them) or a »dir« path (and optionally a list of base names to »exclude« from it), this builds the NixOS configuration for each host (per file) in the context of all configs provided.
    # If »files« is an attr set, exactly one host with the attribute's name as hostname is built for each attribute. Otherwise the default is to build for one host per configuration file, named as the file name without extension or the sub-directory name. Setting »${preface'}.instances« can override this to build the same configuration for those multiple names instead (the specific »name« is passed as additional »moduleArgs« to the modules and can thus be used to adjust the config per instance).
    # All other arguments are as specified by »mkSystemsFlake« and are passed to »mkNixosConfiguration«.
    mkNixosConfigurations = args: let # { files, dir, exclude, ... }
        files = args.files or (builtins.removeAttrs (getNixFiles args.dir) (args.exclude or [ ]));
        files' = if builtins.isAttrs files then files else (builtins.listToAttrs (map (entryPath: let
            stripped = builtins.match ''^(.*)[.]nix[.]md$'' (builtins.baseNameOf entryPath);
            name = builtins.unsafeDiscardStringContext (if stripped != null then (builtins.elemAt stripped 0) else (builtins.baseNameOf entryPath));
        in { inherit name; value = entryPath; }) files));
        moduleArgs = (args.moduleArgs or { }) // { nodes = configs; };

        configs = mapMergeUnique (prelimName: mainModule: (let
            instances = let
                preface = getPreface inputs (moduleArgs // { inherit preface; }) mainModule null; # (we don't yet know the final name)
            in if !(args?files && builtins.isAttrs files) && preface?instances then preface.instances else [ prelimName ];
        in (mapMergeUnique (name: { "${name}" = let
            preface = getPreface inputs (moduleArgs // { inherit preface; }) mainModule name; # (call again, with name)
        in { inherit preface; } // (mkNixosConfiguration (let systemArgs = (
            builtins.removeAttrs args [ "files" "dir" "exclude" "prefix" ]
        ) // {
            inherit name mainModule;
            moduleArgs = (moduleArgs // { inherit preface; });
            nixosArgs = (args.nixosArgs or { }) // {
                specialArgs = (args.nixosArgs.specialArgs or { }) // { inherit preface; }; # make this available early, and only for the main evaluation (+specialisations +containers)
                prefix = (args.nixosArgs.prefix or [ ]) ++ ((args.prefix or (_: [ ])) name);
            };
            extraModules = (args.extraModules or [ ]) ++ [ { imports = [ (args: {
                options.${preface'} = {
                    instances = lib.mkOption { description = "List of host names to instantiate this host config for, instead of just for the file name."; type = lib.types.listOf lib.types.str; readOnly = true; } // (lib.optionalAttrs (!preface?instances) { default = instances; });
                    id = lib.mkOption { description = "This system's ID. If set, »mkSystemsFlake« will ensure that the ID is unique among all »moduleArgs.nodes«."; type = lib.types.nullOr (lib.types.either lib.types.int lib.types.str); readOnly = true; apply = id: if id == null then null else toString id; } // (lib.optionalAttrs (!preface?id) { default = null; });
                    overrideSystemArgs = lib.mkOption { description = "Function that may override any of the arguments to »mkNixosConfiguration«."; type = lib.types.functionTo lib.types.attrs; readOnly = true; } // (lib.optionalAttrs (!preface?overrideSystemArgs) { default = args: args; });
                };
            }) ]; _file = "${dirname}/nixos.nix#mkNixosConfigurations-extraModule"; } ];
        }; in (
            if preface?overrideSystemArgs then systemArgs // (preface.overrideSystemArgs systemArgs) else systemArgs
        ))); }) instances))) (files');

        duplicate = let
            getId = node: name: let id = node.preface.id or null; in if id == null then null else toString id;
            withId = lib.filterAttrs (name: node: (getId node name) != null) configs;
            ids = mapMerge (name: node: { "${getId node name}" = name; }) withId;
        in builtins.removeAttrs withId (builtins.attrValues ids);
    in if duplicate != { } then (
        throw "»${preface'}.id«s are not unique! The following hosts share their IDs with some other host: ${builtins.concatStringsSep ", " (builtins.attrNames duplicate)}"
    ) else configs;

    # Builds a system of NixOS hosts and exports them, plus »apps« and »devShells« to manage them, as flake outputs.
    # All arguments are optional, as long as the default can be derived from the other arguments as passed.
    mkSystemsFlake = lib.makeOverridable (args@{
        # An attrset of imported Nix flakes, for example the argument(s) passed to the flake »outputs« function. All other arguments are optional (and have reasonable defaults) if this is provided and contains »self« and the standard »nixpkgs«. This is also the second argument passed to the individual hosts' top level config files.
        inputs ? { },
        # Arguments »{ files, dir, exclude, }« to »mkNixosConfigurations«, see there for details. May also be a list of those attrsets, in which case those multiple sets of hosts will be built separately by »mkNixosConfigurations«, allowing for separate sets of »peers« passed to »mkNixosConfiguration«. Each call will receive all other arguments, and the resulting sets of hosts will be merged.
        hosts ? ({ dir = "${getFlakeDir inputs.self "Can't determine flake dir from »inputs.self«. Supply »mkSystemsFlake.hosts.dir« explicitly!"}/hosts"; exclude = [ ]; }),
        # List of Modules to import for all hosts, in addition to the default ones in »nixpkgs«. The host-individual module should selectively enable these. Defaults to ».nixosModules.default« of all »moduleInputs«/»inputs« (including »inputs.self«).
        modules ? (getModulesFromInputs moduleInputs),
        # (Subset of) »inputs« that »modules« will be used from. Example: »{ inherit (inputs) self flakeA flakeB; }«.
        moduleInputs ? inputs,
        # List of additional modules to import for all hosts.
        extraModules ? [ ],
        # List of overlays to set as »config.nixpkgs.overlays«. Defaults to ».overlays.default« of all »overlayInputs«/»inputs« (incl. »inputs.self«).
        overlays ? (getOverlaysFromInputs overlayInputs),
        # (Subset of) »inputs« that »overlays« will be used from. Example: »{ inherit (inputs) self flakeA flakeB; }«.
        overlayInputs ? inputs,
        # Additional arguments passed to each module evaluated for the host config (if that module is defined as a function).
        moduleArgs ? { },
        # The »nixosSystem« function defined in »<nixpkgs>/flake.nix«, or equivalent.
        nixosSystem ? inputs.nixpkgs.lib.nixosSystem,
        # Attribute path labels to prepend to option names/paths. Useful for debugging when building multiple systems at once.
        prefix ? (name: [ "[${if renameOutputs == false then name else renameOutputs name}]" ]),
        # If provided, this will be set as »config.nixpkgs.buildPlatform« for all hosts, which in turn enables cross-compilation for all hosts whose »config.nixpkgs.hostPlatform« (the architecture they will run on) does not expand to the same value. Without this, building for other platforms may still work (slowly) if »boot.binfmt.emulatedSystems« on the building system is configured for the respective target(s).
        buildPlatform ? null,
        ## The platforms for which the setup scripts (installation & maintenance/debugging) will be defined. Should include the ».buildPlatform« and/or the target system's »config.nixpkgs.hostPlatform«.
        setupPlatforms ? if inputs?systems then import inputs.systems else [ "aarch64-linux" "x86_64-linux" ],
        ## If provided, then change the name of each output attribute by passing it through this function. Allows exporting of multiple variants of a repo's hosts from a single flake (by then merging the results):
        renameOutputs ? false,
        ## Whether to export the »all-systems« package as »packages.*.default« as well.
        asDefaultPackage ? false,
    ... }: let
        getName = if renameOutputs == false then (name: name) else renameOutputs;
        otherArgs = (builtins.removeAttrs args [ "hosts" "moduleInputs" "overlayInputs" "renameOutputs" "asDefaultPackage" ]) // {
            inherit inputs modules overlays moduleArgs nixosSystem buildPlatform extraModules prefix;
            nixosArgs = (args.nixosArgs or { }) // { modules = (args.nixosArgs.modules or [ ]) ++ [ { imports = [ (args: {
                ${installer}.outputName = getName args.config._module.args.name;
            }) ]; _file = "${dirname}/nixos.nix#mkSystemsFlake-extraModule"; } ]; };
        };
        nixosConfigurations = if builtins.isList hosts then mergeAttrsUnique (map (hosts: mkNixosConfigurations (otherArgs // hosts)) hosts) else mkNixosConfigurations (otherArgs // hosts);
    in let outputs = {
        inherit nixosConfigurations;
    } // (forEachSystem setupPlatforms (buildSystem: let
        pkgs = (import inputs.nixpkgs { inherit overlays; system = buildSystem; });
    in rec {

        apps = lib.mapAttrs (name: system: rec { type = "app"; derivation = writeSystemScripts { inherit name pkgs system; }; program = "${derivation}"; }) nixosConfigurations;

        # dummy that just pulls in all system builds
        packages = let all-systems = pkgs.runCommandLocal "all-systems" { } ''
            mkdir -p $out/systems
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: system: "ln -sT ${system.config.system.build.toplevel} $out/systems/${getName name}") nixosConfigurations)}
            mkdir -p $out/scripts
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: system: "ln -sT ${apps.${name}.program} $out/scripts/${getName name}") nixosConfigurations)}
            mkdir -p $out/inputs
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: { outPath, ... }: "ln -sT ${outPath} $out/inputs/${name}") inputs)}
        ''; in { inherit all-systems; } // (lib.optionalAttrs asDefaultPackage { default = all-systems ; });
        checks.all-systems = packages.all-systems;

    })); in if renameOutputs == false then outputs else {
        nixosConfigurations = mapMergeUnique (k: v: { ${renameOutputs k} = v; }) outputs.nixosConfigurations;
    } // (forEachSystem setupPlatforms (buildSystem: {
        apps = mapMergeUnique (k: v: { ${renameOutputs k} = v; }) outputs.apps.${buildSystem};
        packages.${renameOutputs "all-systems"} = outputs.packages.${buildSystem}.all-systems;
        checks.${renameOutputs "all-systems"} = outputs.checks.${buildSystem}.all-systems;
    })));

    # This makes the »./setup-scripts/*« callable from the command line:
    writeSystemScripts = {
        system, # The NiOS definition of the system that the scripts are supposed to manage.
        name ? system._module.args.name, # The system's name.
        pkgs, # Package set for the host calling these scripts, which is not necessarily the same as »system«'s.
    }: let
        description = ''
            Call per-host setup and maintenance commands. Most importantly, »install-system«.
        '';
        ownPath = if (system.config.${installer}.outputName != null) then "nix run REPO#${system.config.${installer}.outputName} --" else builtins.placeholder "out";
        usageLine = ''
            Usage:
                %s [sudo] [bash] [--FLAG[=value]]... [--] [COMMAND [ARG]...]

                ${lib.optionalString (system.config.${installer}.outputName != null) ''
                    Where »REPO« is the path to the flake repo exporting this system (»${system.config.${installer}.outputName}«) using »mkSystemsFlake«.
                ''}    If the first argument (after the first »--«) is »sudo«, then the program will re-execute itself as root using sudo (minus that »sudo« argument).
                If the (then) first argument is »bash«, or if there are no (more) arguments, it will execute an interactive shell with the »COMMAND«s (bash functions and exported Nix values used by them) sourced.
                If a »FLAG« »--command« is supplied, then the first positional argument (»COMMAND«) is »eval«ed as bash instructions, otherwise the first argument should be one of the »COMMAND«s below, which will be called with the positional CLI »ARG«s as arguments.
                »FLAG«s may be set to customize the behavior of »COMMAND« or any sub-commands it calls.

            »COMMAND« should be one of:%s

            »FLAG«s may be any of:
        ''; # printf string that gets passed the flake path and the COMMANDs list, and that is followed by the FLAGs list
        notesAndExamples = ''

            Examples:

                Install the system »$host« to the image file »/tmp/system-$host.img«:
                    $ nix run .#$host -- install-system /tmp/system-$host.img

                Test a fresh installation of »$host« in a qemu VM:
                    $ nix run .#$host -- run-qemu --install=always

                Run an interactive bash session with the setup functions in the context of the current host:
                    $ nix run /etc/nixos/#$(hostname)
                Now run any of the »COMMAND«s above, or inspect/use the exported Nix variables (»declare -p config_<TAB><TAB>«).

                Run a root session in the context of a different host (useful if Nix is not installed for root on the current host):
                    $ nix run .#other-host -- sudo
        '';
        tools = lib.unique (map (p: p.outPath) (lib.filter lib.isDerivation pkgs.stdenv.allowedRequisites));
        esc = lib.escapeShellArg;
    in pkgs.writeShellScript "scripts-${name}" ''
        self=${builtins.placeholder "out"}

        # if first arg is »sudo«, re-execute this script with sudo (as root)
        if [[ ''${1:-} == sudo ]] ; then shift ; exec sudo --preserve-env=SSH_AUTH_SOCK -- "$self" "$@" ; fi

        # if the (now) first arg is »bash« or there are no args, re-execute this script as bash »--init-file«, starting an interactive bash in the context of the script
        if [[ ''${1:-} == bash ]] || [[ $# == 0 && $0 != ${pkgs.bashInteractive}/bin/bash ]] ; then
            shift ; exec ${pkgs.bashInteractive}/bin/bash --init-file <(echo '
                # prefix the script to also include the default init files
                ! [[ -e /etc/profile ]] || . /etc/profile
                for file in ~/.bash_profile ~/.bash_login ~/.profile ; do
                    if [[ -r $file ]] ; then . $file ; break ; fi
                done ; unset $file

                # add active »hostName« to shell prompt
                PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$}

                source "'"$self"'" ; PATH=$hostPath
            ') -i -s ':' "$@" # execute : (noop) as command, preserve argv
        fi

        # provide installer tools (not necessarily for system.pkgs.config.hostPlatform)
        hostPath=$PATH ; PATH=${lib.makeBinPath tools}

        source ${inputs.functions.lib.bash.generic-arg-parse}
        set -o pipefail -o nounset # (do not rely on errexit)
        generic-arg-parse "$@" || exit

        if [[ ''${args[debug]:-} ]] ; then # for the aliases to work, they have to be set before the functions are parsed
            args[trace]=1
            shopt -s expand_aliases # enable aliases in non-interactive bash
            for control in return exit ; do alias $control='{
                status=$? ; if ! (( status )) ; then '$control' 0 ; fi # control flow return
                if ! PATH=$hostPath "$self" bash ; then '$control' $status ; fi # »|| '$control'« as an error-catch
                #if ! ${pkgs.bashInteractive}/bin/bash --init-file ${system.config.environment.etc.bashrc.source} ; then '$control' $status ; fi # »|| '$control'« as an error-catch
            }' ; done
        fi

        declare -g -A allowedArgs=( ) ; function declare-flag { # 1: context, 2: name, 3?: value, 4: description
            local name=--$2 ; if [[ $3 ]]; then name+='='$3 ; fi ; allowedArgs[$name]="($1) $4"
        }
        declare-flag '*' command "" 'Interpret the first positional argument as bash script (instead of the name of a single command) and »eval« it (with access to all commands and internal functions and variables).'
        declare-flag '*' debug "" 'Hook into any »|| exit« / »|| return« statements and open a shell if they are triggered by an error. Implies »--trace«.'
        declare-flag '*' trace "" "Turn on bash's »errtrace« option before running »COMMAND«."
        declare-flag '*' quiet "" "Try to suppress all non-error output. May also swallow some error related output."
        declare -g -A allowedCommands=( ) ; function declare-command { allowedCommands[$@]=$(< /dev/stdin) ; }
        source ${inputs.functions.lib.bash.generic-arg-verify}
        source ${inputs.functions.lib.bash.generic-arg-help}
        source ${inputs.functions.lib.bash.prepend_trap}
        ${system.config.${installer}.build.scripts { native = pkgs; }}
        if [[ ''${args[help]:-} ]] ; then (
            functionDoc= ; while IFS= read -u3 -r name ; do
                functionDoc+=$'\n\n    '"$name"$'\n        '"''${allowedCommands[$name]//$'\n'/$'\n        '}" #$'\n\n'
            done 3< <( printf '%s\n' "''${!allowedCommands[@]}" | LC_ALL=C sort )
            generic-arg-help "${ownPath}" "$functionDoc" ${esc description} ${esc notesAndExamples} ${esc usageLine} || exit
        ) ; \exit 0 ; fi

        undeclared=x-.* exitCode=3 generic-arg-verify || \exit

        # either call »argv[0]« with the remaining parameters as arguments, or if »$1« is »-c« eval »$2«.
        if [[ ''${args[trace]:-} ]] ; then set -x ; fi
        if [[ ''${args[command]:-} ]] ; then
            command=''${argv[0]:?'With --command, the first positional argument must specify the commands to run.'} || exit
            argv=( "''${argv[@]:1}" ) ; set -- "''${argv[@]}" ; eval "$command" || exit
        else
            entry=''${argv[0]:?} || exit
            argv=( "''${argv[@]:1}" ) ; "$entry" "''${argv[@]}" || exit
        fi
    '';

}
