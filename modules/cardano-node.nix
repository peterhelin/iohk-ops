{ config, pkgs, lib, options, ... }:

with (import ./../lib.nix);

let
  cfg = config.services.cardano-node;
  name = "cardano-node";
  stateDir = "/var/lib/cardano-node/";
  cardano = (import ./../default.nix { }).cardano-sl-static;
  distributionParam = "(${toString cfg.genesisN},${toString cfg.totalMoneyAmount})";
  rnpDistributionParam = "(${toString cfg.genesisN},50000,${toString cfg.totalMoneyAmount},0.99)";
  smartGenIP = builtins.getEnv "SMART_GEN_IP";

  command = toString [
    cfg.executable
    (optionalString (cfg.publicIP != null) "--address ${cfg.publicIP}:${toString cfg.port}")
    (optionalString (cfg.type != "edge") "--listen ${cfg.privateIP}:${toString cfg.port}")
    # Profiling
    # NB. can trigger https://ghc.haskell.org/trac/ghc/ticket/7836
    # (it actually happened)
    #"+RTS -N -pa -hb -T -A6G -qg -RTS"
    # Event logging (cannot be used with profiling)
    #"+RTS -N -T -l -A6G -qg -RTS"
    "--no-ntp" # DEVOPS-160
    (optionalString cfg.stats "--stats")
    (optionalString (!cfg.productionMode) "--rebuild-db")
    (optionalString (!cfg.productionMode) "--spending-genesis ${toString cfg.nodeIndex}")
    (optionalString (!cfg.productionMode) "--vss-genesis ${toString cfg.nodeIndex}")
    (optionalString (cfg.distribution && !cfg.productionMode && cfg.richPoorDistr) (
       "--rich-poor-distr \"${rnpDistributionParam}\""))
    (optionalString (cfg.distribution && !cfg.productionMode && !cfg.richPoorDistr) (
       if cfg.bitcoinOverFlat
       then "--bitcoin-distr \"${distributionParam}\""
       else "--flat-distr \"${distributionParam}\""))
    (optionalString cfg.jsonLog "--json-log ${stateDir}/jsonLog.json")
    (optionalString (cfg.statsdServer != null) "--metrics +RTS -T -RTS --statsd-server ${cfg.statsdServer}")
    (optionalString (cfg.serveEkg)             "--ekg-server ${cfg.privateIP}:8080")
    (optionalString (cfg.productionMode && cfg.nodeName != "explorer")
      "--keyfile ${stateDir}key${toString cfg.nodeIndex}.sk")
    (optionalString (cfg.productionMode && cfg.systemStart != 0) "--system-start ${toString cfg.systemStart}")
    (optionalString cfg.supporter "--supporter")
    "--log-config ${./../static/csl-logging.yaml}"
    "--logs-prefix /var/lib/cardano-node"
    "--db-path ${stateDir}/node-db"
    (optionalString (!cfg.enableP2P) "--kademlia-explicit-initial --disable-propagation ${smartGenPeer}")
    # (optionalString (cfg.type == "relay") "--kademlia /run/keys/kademlia.yaml")
    (optionalString (cfg.topologyFile != null) "--topology ${cfg.topologyFile}")
    "--node-id ${cfg.nodeName}"
    "--node-type ${cfg.type}"
    cfg.extraArgs
  ];
in {
  options = {
    services.cardano-node = {
      enable = mkEnableOption name;
      port = mkOption { type = types.int; default = 3000; };
      systemStart = mkOption { type = types.int; default = 0; };

      type      = mkOption { type = types.enum [ "core" "relay" "explorer" "report-server" "edge" ]; default = null; };

      enableP2P = mkOption { type = types.bool; default = false; };
      supporter = mkOption { type = types.bool; default = false; };
      dhtKey = mkOption {
        type = types.str;
        description = "base64-url string describing dht key";
      };
      extraArgs = mkOption {
        type = types.str;
        default = "";
      };
      productionMode = mkOption {
        type = types.bool;
        default = false;
      };
      saveCoreDumps = mkOption {
        type = types.bool;
        default = false;
        description = "automatically save coredumps when cardano-node segfaults";
      };

      executable = mkOption {
        type = types.str;
        description = "Executable to run as the daemon.";
        default = "${cardano}/bin/cardano-node-simple";
      };
      autoStart = mkOption { type = types.bool; default = true; };

      topologyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      genesisN = mkOption { type = types.int; };
      slotDuration = mkOption { type = types.int; };
      networkDiameter = mkOption { type = types.int; };
      mpcRelayInterval = mkOption { type = types.int; };
      statsdServer = mkOption {
        type = types.nullOr types.str;
        description = "IP:Port of the EKG telemetry sink";
        default = null;
      };
      serveEkg = mkOption {
        type = types.bool;
        description = "Serve EKG raw on port 80";
        default = false;
      };

      stats = mkOption { type = types.bool; default = false; };
      jsonLog = mkOption { type = types.bool; default = true; };
      totalMoneyAmount = mkOption { type = types.int; default = 100000; };
      distribution = mkOption {
        type = types.bool;
        default = true;
        description = "pass distribution flag";
      };
      bitcoinOverFlat = mkOption {
        type = types.bool;
        default = false;
        description = "If distribution is on, use bitcoin distribution. Otherwise flat";
      };
      richPoorDistr = mkOption {
        type = types.bool;
        default = false;
        description = "Enable rich-poor distr";
      };
      hasExplorer = mkOption {
        type = types.bool;
        default = false;
        description = "Does the node has explorer running?";
      };

      nodeIndex = mkOption { type = types.int; };
      nodeName  = mkOption { type = types.str; };

      publicIP = mkOption {
        type = types.nullOr types.str;
        description = "Public IP to advertise to peers";
        default = null;
      };

      privateIP = mkOption {
        type = types.str;
        description = "Private IP to bind to";
        default = "0.0.0.0";
      };

      neighbours = mkOption {
        default = [];
        # type = types.list;
        description = ''List of name:ip pairs of neighbours.'';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
    { assertion = cfg.type != null;
      message = "services.cardano-node.type must be set to one of: core relay other"; }
    ];

    users = {
      users.cardano-node = {
        uid             = 10014;
        description     = "cardano-node server user";
        group           = "cardano-node";
        home            = stateDir;
        createHome      = true;
        extraGroups     = [ "keys" ];
      };
      groups.cardano-node = {
        gid = 123123;
      };
    };

    services.cardano-node.dhtKey = mkDefault (genDhtKey cfg.nodeIndex);

    networking.firewall = {
      allowedTCPPorts = [ cfg.port 8080 ]; ## 8080 is EKG

      # TODO: securing this depends on CSLA-27
      # NOTE: this implicitly blocks DHCPCD, which uses port 68
      allowedUDPPortRanges = [ { from = 1024; to = 65000; } ];
    };

    # Workaround for CSL-1320
    systemd.services.cardano-restart = let
      getDailyTime = nodeIndex: let
          # how many minutes between each node restarting
          minute = mod (nodeIndex * 4) 60;
        in "0/2:${toString minute}";
    in {
      script = ''
        /run/current-system/sw/bin/systemctl restart cardano-node
      '';
      # Reboot cardano-node every 4h, offset by node id (in ${interval} minute intervals)
      startAt = getDailyTime cfg.nodeIndex;
    };

    systemd.services.cardano-node = {
      description   = "cardano node service";
      after         = [ "network.target" ];
      wantedBy = optionals cfg.autoStart [ "multi-user.target" ];
      script = let
        keyId = "key" + toString cfg.nodeIndex;
        key = keyId + ".sk";
      in ''
        [ -f /run/keys/${keyId} ] && cp /run/keys/${keyId} ${stateDir}${key}
        ${optionalString (cfg.saveCoreDumps) ''
          # only a process with non-zero coresize can coredump (the default is 0)
          ulimit -c unlimited
        ''}
        exec ${command}
      '';
      serviceConfig = {
        User = "cardano-node";
        Group = "cardano-node";
        # Allow a maximum of 5 retries separated by 30 seconds, in total capped by 200s
        Restart = "always";
        RestartSec = 30;
        StartLimitInterval = 200;
        StartLimitBurst = 5;
        KillSignal = "SIGINT";
        WorkingDirectory = stateDir;
        PrivateTmp = true;
      };
    };
  };
}
