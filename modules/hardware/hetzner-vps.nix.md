/*

# Hetzner Cloud VPS Base Config

This is "device" type specific configuration for Hetzner's cloud VPS VMs.


## Installation / Testing

Hetzner Cloud unfortunately doesn't let one directly upload complete images to be deployed on a new server.
Since the VPSes are Qemu VMs, [installed](../../lib/setup-scripts/README.md#install-system-documentation) images can be tested locally in qemu:
```bash
 nix run '.#<hostname>' -- sudo run-qemu $image
```
Once the system works locally, one can (for example) create a new server instance, boot it into rescue mode, and:
```bash
cat $image | zstd | ssh $newServerIP 'zstdcat >/dev/sda && sync'
```
If the image is very large, even if it is mostly empty and with compression, this can take quite a while.
Declaring a smaller image size and expanding it on boot may be a workaround, but (since it depends on the disk partitioning and filesystems used) is out of scope here.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: args@{ config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.hardware.hetzner-vps;
in {

    options.${prefix} = { hardware.hetzner-vps = {
        enable = lib.mkEnableOption "the core hardware configuration for Hetzner VPS (virtual) hardware";
    }; };

    config = lib.mkIf cfg.enable ({

        ${prefix}.bootloader.extlinux.enable = true;

        networking.interfaces.eth0.useDHCP = true;
        networking.interfaces.eth0.ipv6.routes = [ { address = "::"; prefixLength = 0; via = "fe80::1"; } ];
        networking.timeServers = [ "ntp1.hetzner.de" "ntp2.hetzner.com" "ntp3.hetzner.net" ]; # overwrite NTP

        profiles.qemu-guest.enable = true;

    });
}
