#!/usr/bin/env bash
: << '```bash'

# Installer Script Overrides (Example)

This is an example on how to customize the default installation process.
The [`config.installer.commands.*`](../modules/installer.nix.md) can be used for some per-host customization, but for further reaching changes that are supposed to affect all hosts in a  configuration, it may be necessary or more appropriate to extend/override the [default installer functions](../lib/setup-scripts/).

This file would need to be included in the configuration like this:
```nix
{ config.installer.scripts.my-customizations = { path = .../installer.sh.md; order = 1500; }; }
```

## Implementation

```bash

## Replace/Extend a Command or Function
# For example, »nixos-install-cmd $mnt $topLevel« gets called to perform the last step(s) of the installation, after the »/nix/store« contents has been copied to the new filesystems.
# Usually it just installs the bootloader, but we can hook into the function to have it do additional stuff:
copy-function nixos-install-cmd nixos-install-cmd-default # (if we still want to call the previous implementation)
function nixos-install-cmd {( # 1: mnt, 2: topLevel
    # ... do things beforehand ...
    nixos-install-cmd-default "$@"
    # ... do things afterwards ...
)}
# This schema works with any of the existing commands or functions they use.

## Add a New COMMAND
# Any bash function defined in any of the setup scripts can be called as »nix run .#$hostname -- COMMAND«, but a proper COMMAND should be documented as such:
declare-command my-thing withThese coolArguments << 'EOD'
This does my thing with these cool arguments -- duh!
EOD
declare-flag my-thing laser-color COLOR "Color of the laser used for my thing."
function run-qemu { # 1: withThese, 2: coolArguments
    local withThese=$1
    local coolThings=$2
    echo "I am playing $withThese to shoot $coolArguments with ${args[laser-color]:-red} lasers!"
}
# $ nix run .#example -- my-thing --laser-color=powerful 'friends' -- 'nothing, cuz that would be irresponsible,'
