{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.nftables;

  tableSubmodule =
    { name, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable this table.";
        };

        name = lib.mkOption {
          type = lib.types.str;
          description = "Table name.";
        };

        content = lib.mkOption {
          type = lib.types.lines;
          description = "The table content.";
        };

        family = lib.mkOption {
          description = "Table family.";
          type = lib.types.enum [
            "ip"
            "ip6"
            "inet"
            "arp"
            "bridge"
            "netdev"
          ];
        };
      };

      config = {
        name = lib.mkDefault name;
      };
    };

  enabledTables = lib.filterAttrs (_: table: table.enable) cfg.tables;

  # `delete table` fails on a table which is not loaded, so every deletion is
  # preceded by a `table` statement, which creates the table when missing
  deletionsFile = pkgs.writeText "nftables-deletions.nft" (
    lib.concatStrings (
      lib.mapAttrsToList (_: table: ''
        table ${table.family} ${table.name}
        delete table ${table.family} ${table.name}
      '') enabledTables
    )
  );

  # the deletions belonging to the ruleset which is currently loaded
  # a table dropped from the configuration is only named by the generation that
  # created it, so its deletion has to survive into the next one as mutable state.
  stateFile = "/var/lib/nftables/deletions.nft";

  rulesScript = pkgs.writeText "nftables-ruleset.nft" ''
    include "${stateFile}"
    include "${deletionsFile}"

    ${lib.concatStrings (
      lib.mapAttrsToList (_: table: ''
        table ${table.family} ${table.name} {
          ${table.content}
        }
      '') enabledTables
    )}
  '';

  # `nft -f` applies a whole file as a single netlink transaction, so the old
  # tables are replaced by the new ones without ever leaving the host unfiltered
  startScript = pkgs.writeShellScript "nftables-start" ''
    set -e
    ${lib.getExe cfg.package} -f ${rulesScript}
    ${lib.getExe' config.programs.coreutils.package "cp"} ${deletionsFile} ${stateFile}
  '';

  # the state file is truncated rather than removed, so that a subsequent start
  # can `include` it again
  stopScript = pkgs.writeShellScript "nftables-stop" ''
    set -e
    ${lib.getExe cfg.package} -f ${stateFile}
    : > ${stateFile}
  '';
in
{
  imports = [
    ./providers.services.nix
    ./providers.firewall.nix
  ];

  options.services.nftables = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [nftables](${pkgs.nftables.meta.homepage}) as a system service.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nftables;
      defaultText = lib.literalExpression "pkgs.nftables";
      description = ''
        The package to use for `nftables`.
      '';
    };

    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "enp0s2" ];
      description = ''
        Traffic arriving on these interfaces is accepted unconditionally,
        without regard for the ports opened through {option}`providers.firewall`.

        The loopback interface is always trusted and cannot be removed from
        this list.
      '';
    };

    rejectPackets = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether refused packets are rejected rather than dropped. When enabled an
        ICMP "port unreachable" error is sent back to the client, or a TCP reset in
        case of TCP, instead of the packet being silently ignored.

        Rejecting makes connections to closed ports fail immediately rather than
        time out, at the cost of making the host trivial to port scan.
      '';
    };

    tables = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule tableSubmodule);
      default = { };
      example = lib.literalExpression ''
        {
          filter = {
            family = "inet";
            content = '''
              chain input {
                type filter hook input priority filter; policy drop;
                tcp dport 22 accept
              }
            ''';
          };
        }
      '';
      description = ''
        Tables to be added to the ruleset.
        Tables will be added together with delete statements to clean up the
        table before every update.
      '';
    };

    # exposed so that providers.services.nix can name it: a unit which reads this file has
    # to name it to be rebuilt when it changes, and it cannot reach it through
    # `environment.etc`, which is where implementations put the unit itself.
    startScript = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = startScript;
      description = "Generated by this module, named by its units.";
    };

    # exposed so that providers.services.nix can name it: a unit which reads this file has
    # to name it to be rebuilt when it changes, and it cannot reach it through
    # `environment.etc`, which is where implementations put the unit itself.
    stopScript = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = stopScript;
      description = "Generated by this module, named by its units.";
    };

    # exposed so that providers.services.nix can name it: a unit which reads this file has
    # to name it to be rebuilt when it changes, and it cannot reach it through
    # `environment.etc`, which is where implementations put the unit itself.
    stateFile = lib.mkOption {
      type = lib.types.raw;
      internal = true;
      readOnly = true;
      default = stateFile;
      description = "Generated by this module, named by its units.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.nftables.trustedInterfaces = [ "lo" ];

    environment.systemPackages = [ cfg.package ];

    # `post` was finit's stop action - the thing it runs when the task goes away - and the
    # shutdown side of the trunk is what means that on every implementation
    # this module supplies an implementation for `providers.firewall`
    providers.firewall.backend = "nftables";

  };
}
