# The default »config« flake input for this repo. It influences the exports made by this repo's main flake.
# To customize these options, copy the directory containing this file into a calling flake, and set »inputs.<this-repo>.inputs.config.url = "path:./rel/path/to/copied/dir"«.
{ outputs = { ... }: {

    # Moving from a monorepo (`nixpkgs`) to compositions of independent repositories, it is likely that different things will end up with the same name.
    # The hierarchical structure and input/output sematic of Nix flakes can avoid most naming conflicts.
    #
    # NixOS modules, however, define their configuration options in a hierarchical, but global, namespace, and some of those options are necessarily meant to be accessed from modules external to the defining flake.
    # Usually, for any given module, an importing flake would only have the option to either include a module or not. If two modules define options of conflicting names, then they can't be imported at the same time, even if they could otherwise coexist.
    #
    # The only workaround (that I could come up with) is to have a flake-level option that allows to change the names of the options defined in the modules exported by that flake.
    # To rename the options exported by this flake's modules, change the values of this attrset:
    rename = {
        installer = "installer"; # config.${installer}
        setup = "setup"; # config.${setup}
        preface = "preface"; # config.${preface}
        extlinux = "extlinux"; # config.boot.loader.${extlinux}
        preMountCommands = "preMountCommands"; # config.fileSystems.*.${preMountCommands}
    };
}; }
