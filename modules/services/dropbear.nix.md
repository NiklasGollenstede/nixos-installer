/*

# Dropbear SSHd Configuration

OpenSSH adds ~35MB closure size. Let's try `dropbear` instead!


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    prefix = inputs.config.prefix;
    cfg = config.${prefix}.services.dropbear;
in {

    options.${prefix} = { services.dropbear = {
        enable = lib.mkEnableOption "dropbear SSH daemon";
        port = lib.mkOption { description = "TCP port to listen on and open a firewall rule for."; type = lib.types.port; default = 22; };
        socketActivation = lib.mkEnableOption "socket activation mode for dropbear, where systemd launches dropbear on incoming TCP connections, instead of dropbear permanently running and listening on its TCP port";
        rootKeys = lib.mkOption { description = "Literal lines to write to »/root/.ssh/authorized_keys«"; default = ""; type = lib.types.lines; };
        hostKeys = lib.mkOption { description = "Location of the host key(s) to use. If empty, then a key(s) will be generated at »/etc/dropbear/dropbear_(ecdsa/rsa)_host_key« on first access to the server."; default = [ ]; type = lib.types.listOf lib.types.path; };
    }; };

    config = let
        defaultArgs = lib.concatStringsSep "" [
            "${pkgs.dropbear}/bin/dropbear"
            (if cfg.hostKeys == [ ] then (
                " -R" # generate host keys on connection
            ) else lib.concatMapStrings (path: (
                " -r ${path}"
            )) cfg.hostKeys)
        ];

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        networking.firewall.allowedTCPPorts = [ cfg.port ];

    }) (lib.mkIf (!cfg.socketActivation) {

        systemd.services."dropbear" = {
            description = "dropbear SSH server (listening)";
            wantedBy = [ "multi-user.target" ]; after = [ "network.target" ];
            serviceConfig.ExecStartPre = lib.mkIf (cfg.hostKeys == [ ]) "${pkgs.coreutils}/bin/mkdir -p /etc/dropbear/";
            serviceConfig.ExecStart = lib.concatStringsSep "" [
                defaultArgs
                " -p ${toString cfg.port}" # listen on TCP/${port}
                " -F -E" # don't fork, use stderr
            ];
            #serviceConfig.PIDFile = "/var/run/dropbear.pid"; serviceConfig.Type = "forking"; after = [ "network.target" ]; # alternative to »-E -F« (?)
        };

    }) (lib.mkIf (cfg.socketActivation) {

        systemd.sockets.dropbear = { # start a »dropbear@.service« on any number of TCP connections on port 22
            conflicts = [ "dropbear.service" ];
            listenStreams = [ "${toString cfg.port}" ];
            socketConfig.Accept = "yes";
            #socketConfig.Restart = "always";
            wantedBy = [ "sockets.target" ]; # (isn't this implicit?)
        };
        systemd.services."dropbear@" = {
            description = "dropbear SSH server (per-connection)";
            after = [ "syslog.target" ];
            serviceConfig.PreExec = lib.mkIf (cfg.hostKeys == [ ]) "${pkgs.coreutils}/bin/mkdir -p /etc/dropbear/"; # or before socket?
            serviceConfig.ExecStart = lib.concatStringsSep "" [
                "-"   # for the most part ignore exit != 0
                defaultArgs
                " -i" # handle a single connection on stdio
            ];
            serviceConfig.StandardInput = "socket";
        };

    }) (lib.mkIf (cfg.rootKeys != "") {

        systemd.tmpfiles.rules = [ (lib.wip.mkTmpfile { type = "L+"; path = "/root/.ssh/authorized_keys"; argument = pkgs.writeText "root-ssh-authorized_keys" cfg.rootKeys; }) ];

    }) ]);

}
