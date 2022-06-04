
# Work In Progress Nix(OS) Library

The idea of this repo / flake is that whenever I have a Nix function, NixOS Module, nixpkgs package/overlay, related bash script, or combination of those that I need in more than one project, I first put it here so that it can be shared between them.

Eventually I may decide to move parts of this into their own flake repository, but as long as they live here, APIs are not necessarily stable.

The more interesting of the components currently in this repository are largely concerned with good structures for Nix flakes, in particular those defining NixOS configurations, and installing hosts from those configurations.


## Repo Layout

This is a nix flake repository, so [`flake.nix`](./flake.nix) is the entry point and export mechanism for almost everything.

[`lib/`](./lib/) adds additional library functions as `.wip` to the default `nixpkgs.lib` and exports the whole thing as `lib`. Other folders in this repo may thus use them as `inputs.self.lib.wip.*`. \
[`lib/setup-scripts/`](./lib/setup-scripts/) contains bash scripts that integrate with the options defined in [`modules/fs/`](./modules/fs/) (esp. [`modules/fs/disks.nix.md`](./modules/fs/disks.nix.md)) and some default options to do flexible and fully automated installations of configured NixOS hosts.

[`modules/`](./modules/) contains NixOS configuration modules. Added options' names start with `wip.` (or a custom prefix, see [Namespacing](#namespacing-in-nixos)).
The modules are inactive by default, and are, where possible, designed to be independent from each other and the other things in this repo. Some though do have dependencies on added or modified packages, or other modules in the same directory.
[`modules/default.nix`](./modules/default.nix) exports an attr set of the modules defined in the individual files, which is also what is exported as `flake#outputs.nixosModules` and merged as `flake#outputs.nixosModule`.

[`overlays/`](./overlays/) contains nixpkgs overlays. Some modify packages from `nixpkgs`, others add packages not in there (yet).
[`overlays/default.nix`](./overlays/default.nix) exports an attr set of the overlays defined in the individual files, which is also what is exported as `flake#outputs.overlays` and merged as `flake#outputs.overlay`. Additionally, the added or modified packages are exported as `flake#outputs.packages.<arch>.*`.

[`patches/`](./patches/) contains patches which are either applied to the flake's inputs in [`flake.nix`](./flake.nix) or to packages in one of the [`overlays/`](./overlays/).

[`hosts/`](./hosts/) contains the main NixOS config modules for each host. Generally, there is one file for each host, but the [flake](./flake.nix) can be instructed to reuse the config for multiple hosts (in which case the module should probably interpret the `name` argument passed to it).
Any `preface.*` options have to be set in the first sub-module in these files (`## Hardware` section). \
This flake only defines a single [`example`](./hosts/example.nix.md) host meant to demonstrate how other flakes can use the (NixOS) flake library framework.

[`example/`](./example/) contains an example of adjusting the [installation](./example/install.sh.md) script for the hosts and this flake's [default config](./example/defaultConfig/) (see [Namespacing](#namespacing-in-nixos)).


## Namespacing in NixOS

One of the weak points of NixOS is namespacing. NixOS is traditionally based on the `nixpkgs` monorepo.

The `pkgs` package set is intentionally a global namespace, so that different parts of the system by default use the same instance of each respective package (unless there is a specific reason not to).

The caller to the top-level function constructing a NixOS system can provide `lib` as a set of Nix library functions. This library set is provided as global argument to all imported modules. `nixpkgs` has its default `lib` set, which its modules depend on.
If a flake exports `nixosModules` to be used by another flake to construct systems, then those modules either need to restrict themselves to the default `lib` (in the expectation that that is what will be passed) or instruct the caller to attach some additional functions (exported together with the modules) to `lib`. The former leads to code duplication within the modules, the latter is an additional requirement on the caller, and since `lib` is global, naming conflicts in the `lib` required by different modules are quite possible. The same problem applies to the strategy of supplying additional global arguments to the modules.

Since a nix flake exports instantiated Nix language constructs, not source code, it is possible to define the modules in their source code files wrapped in an outer function, which gets called by the exporting flake before exporting. Consequently, it can supply arguments which are under control of the module author, providing a library set tailored to and exposed exclusively to the local modules, thus completely avoiding naming conflicts.

NixOS modules however define their configuration options in a hierarchical, but global, namespace, and some of those options are necessarily meant to be accessed from modules external to the defining flake.
Usually, for any given module, an importing flake would only have the option to either include a module or not. If two modules define options of conflicting names, then they can't be imported at the same time, even if they could otherwise coexist.

The only workaround (that I could come up with) is to have a flake-level option that allows to change the names of the options defined in the modules exported by that flake, for example by changing their first hierarchical label.
Since flakes are purely functional, the only way to provide configuration to a flake as a whole (as opposed to exporting parts of the flake as functions, which would break the convention on flake exports) is via the flakes `inputs`, and those inputs must be flakes themselves.
The inputs have defaults defined by the flake itself, but can be overridden by the importing flake.

A flake using the modules exported by this flake may thus accept the default that all options are defined under the prefix `wip.`, or it may override its `config` input by a flake of the same shape as [`example/defaultConfig/`](./example/defaultConfig/) but with a different `prefix`.
As a local experiment, the result of running this in a `nix repl` is sufficient:
```nix
:b (import <nixpkgs> { }).writeTextDir "flake.nix" ''
    { outputs = { ... }: {
        prefix = "<str>";
    }; }
''
```


## Other Concepts

### `.xx.md` files

Often, the concept expressed by a source code file is at least as important as the concrete implementation of it.
`nix` unfortunately isn't super readable and also does not have documentation tooling support nearly on par with languages like TypeScript.

Embedding the source code "file" within a MarkDown file emphasizes the importance of textual expressions of the motivation and context of each piece of source code, and should thus incentivize writing sufficient documentation.
Having the documentation right next to the code should also help against documentation rot.

Technically, Nix (and most other code files) don't need to have any specific file extension. By embedding the MarkDown header in a block comment, the file can still be a valid source code file, while the MarDown header ending in a typed code block ensures proper syntax highlighting of the source code in editors or online repos.


## Notepad

### `nix repl`

```nix
pkgs = import <nixpkgs> { }
:lf . # load CWD's flake's outputs as variables
pkgs = nixosConfigurations.target.pkgs
lib = lib { inherit pkgs; inherit (pkgs) lib; }
```


### TODOs

