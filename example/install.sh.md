#!/usr/bin/env bash
: << '```bash'

# System Installer Script

This is a minimal example for a NixOS system installation function using the functions defined in [`../lib/setup-scripts/`](../lib/setup-scripts/). See its [README](../lib/setup-scripts/README.md) for more documentation.


## Implementation

```bash
function install-system {( set -eu # 1: blockDev
    prepare-installer "$@"
    do-disk-setup "$1"
    install-system-to $mnt prompt=true
)}
