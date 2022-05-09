# The default »config« of <github:NiklasGollenstede/nix-wiplib>.
# (Not a convention-conformant flake, just a workaround to supply configuration to a flake as a flake input.)
{ outputs = { ... }: {
    prefix = "wip"; # The prefix to define NixOS configuration options as.
}; }
