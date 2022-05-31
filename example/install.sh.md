#!/usr/bin/env bash
: << '```bash'

# System Installer Script

This is a minimal example for an adjusted NixOS system installation using the functions defined in [`../lib/setup-scripts/`](../lib/setup-scripts/).
See its [README](../lib/setup-scripts/README.md) for more documentation.


## (Example) Implementation

```bash

# Replace the entry point with the same function:
function install-system {( set -eu # 1: blockDevs
    prepare-installer "$@"
    do-disk-setup "${argv[0]}"
    init-or-restore-system
    install-system-to $mnt
)}

# ... could also replace any other function(s) ...
