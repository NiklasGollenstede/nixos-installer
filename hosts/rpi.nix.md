/*

# Raspberry PI Example

## Installation

Default installation according to [`install-system`](../lib/setup-scripts/README.md#install-system-documentation):
```bash
 nix run '.#rpi' -- install-system $DISK
```
Then connect `$DISK` to a PI, boot it, and (not much, because nothing is installed).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
in { imports = [ ({ ## Hardware

    wip.preface.hardware = "aarch64";  system.stateVersion = "21.11";
    wip.hardware.raspberry-pi.enable = true;

    wip.fs.disks.devices.primary.size = 31914983424; # exact size of the disk/card

    ## Minimal automatic FS setup
    wip.fs.boot.enable = true;
    wip.fs.temproot.enable = true;
    wip.fs.temproot.temp.type = "tmpfs";
    wip.fs.temproot.local.type = "bind";
    wip.fs.temproot.local.bind.base = "f2fs";
    wip.fs.temproot.remote.type = "none";

}) ({ ## Temporary Test Stuff

    services.getty.autologinUser = "root";

}) ]; }
