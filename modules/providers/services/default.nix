{
  config,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  pathOrStr = with lib.types; coercedTo path (x: "${x}") str;
  program =
    lib.types.coercedTo (
      lib.types.package
      // {
        # require mainProgram for this conversion
        check = v: v.type or null == "derivation" && v ? meta.mainProgram;
      }
    ) lib.getExe pathOrStr
    // {
      description = "main program, path or command";
      descriptionClass = "conjunction";
    };

  # a name which resolves to nothing compiles to a dependency no backend can ever satisfy, so
  # the unit silently never starts. this is a local property - no traversal needed.
  danglingEdges = lib.concatLists (
    lib.mapAttrsToList (
      name: unit: map (dep: "${name} -> ${dep}") (lib.filter (dep: !(cfg.units ? ${dep})) unit.requires)
    ) cfg.units
  );

  # whether a unit can reach itself is a global property, so this one does need the walk.
  # `path` is the chain currently being descended and catches back-edges; `visited` memoises
  # subtrees already proven clean, without which every diamond in the graph - and a trunk level
  # requiring all of its dependants makes them ubiquitous - is re-explored once per branch.
  detect =
    path: visited: name:
    if lib.elem name path then
      {
        cycle = path ++ [ name ];
        inherit visited;
      }
    else if visited ? ${name} then
      {
        cycle = null;
        inherit visited;
      }
    else
      let
        step = acc: dep: if acc.cycle != null then acc else detect (path ++ [ name ]) acc.visited dep;

        # dangling names are reported by their own assertion; filtering them here keeps this
        # from dying on an attribute lookup before that assertion gets to say anything useful
        res = lib.foldl step {
          cycle = null;
          inherit visited;
        } (lib.filter (dep: cfg.units ? ${dep}) (cfg.units.${name}.requires or [ ]));
      in
      {
        inherit (res) cycle;
        # marked clean only once the whole subtree came back clean, so `visited` means
        # "proven acyclic" rather than "seen, outcome unknown"
        visited = res.visited // {
          ${name} = true;
        };
      };

  # the graph is disconnected - a unit which requires nothing and which nothing requires is
  # still a unit - so every name is a potential root. each gets a fresh `path` but inherits
  # the accumulated `visited`, keeping the total work linear in edges.
  scan = lib.foldl (acc: name: if acc.cycle != null then acc else detect [ ] acc.visited name) {
    cycle = null;
    visited = { };
  } (lib.attrNames cfg.units);
in
{
  imports = [ ./trunk.nix ];

  options.providers.services = {
    supportedFeatures = {
      startTimeout = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can bound how long a
          unit may take to become ready before it is considered failed.

          When `false`, a unit which never becomes ready stalls every unit which requires it,
          directly or transitively, for the remainder of the boot.
        '';
      };

      stopTimeout = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can bound how long a
          unit may take to stop before it is killed outright.
        '';
      };

      nativeAnchors = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation has a first-class
          process-less unit, as opposed to one emulated with a no-op command.
        '';
      };

      nativeStartOnlyEdges = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can express a
          dependency which gates starting without also propagating stops, as opposed to one
          emulated by latching the dependency's readiness behind a separate unit.
        '';
      };
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "none" ];
      default = "none";
      description = ''
        The selected module which should implement functionality for the {option}`providers.services` contract.
      '';
    };

    units = lib.mkOption {
      default = { };
      description = ''
        The system's service graph.

        A unit starts when, and only when, every unit it requires has become ready. There is no
        other mechanism for starting one: no runlevels, no enablement, no activation events. A
        unit which requires nothing starts immediately, because its requirements are trivially
        met.

        Dependencies govern starting only. Once a unit is running it is unaffected by what
        happens to the units it required - if one of them stops, crashes, or restarts, this unit
        keeps running. Nothing in the graph stops anything; units are only ever stopped by
        shutdown or by reconfiguration.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              type = lib.mkOption {
                type = lib.types.enum [
                  "service"
                  "oneshot"
                  "anchor"
                ];
                default = "service";
                description = ''
                  The kind of unit.

                  `service` is a long-running process. `oneshot` is a command which runs to
                  completion and is ready once it has exited successfully.

                  `anchor` is a unit with no process at all, ready once its own requirements
                  are. Anchors exist to be named, so a unit can say "after the system is
                  basically up" without naming the units that means. In practice they are the
                  trunk, and ordinary modules have no reason to declare one - an interchangeable
                  implementation should be selected by a `providers.` contract and define the
                  shared unit name directly, rather than hiding behind an anchor.
                '';
              };

              description = lib.mkOption {
                type = lib.types.str;
                description = ''
                  A short human-readable description of this unit.
                '';
              };

              command = lib.mkOption {
                type = lib.types.nullOr program;
                default = null;
                description = ''
                  The command this unit runs. Required for `service` and `oneshot` units, and
                  invalid for `anchor` units, which have no process.
                '';
              };

              readiness = lib.mkOption {
                type = lib.types.enum [
                  "fork"
                  "pidfile"
                  "notify"
                ];
                default = "fork";
                description = ''
                  How this unit reports that it has become ready, and so how units requiring it
                  learn they may start. Only meaningful for `service` units - a `oneshot` is
                  ready once it exits successfully, and an `anchor` once its requirements are
                  met.

                  `notify` waits for an `sd_notify`-style `READY=1` on the notification socket.
                  `pidfile` waits for the daemon to background itself and write
                  {option}`pidFile`. `fork` treats the unit as ready the moment it has been
                  forked, which is a lie for anything doing real startup work, but is the only
                  option left for a daemon that cannot report readiness at all.
                '';
              };

              pidFile = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                description = ''
                  The file this unit writes its process ID to. Required when {option}`readiness`
                  is `pidfile`.
                '';
              };

              requires = lib.mkOption {
                type = with lib.types; listOf str;
                default = lib.optional (cfg.trunk.enable && !(lib.elem name cfg.trunk.levels)) (
                  lib.head cfg.trunk.levels
                );
                defaultText = lib.literalExpression "[ (lib.head config.providers.services.trunk.levels) ]";
                description = ''
                  The units which must be ready before this one starts. Losing one afterwards
                  has no effect on this unit.

                  At most one of these may be a trunk level - see
                  {option}`providers.services.trunk.levels`.

                  A unit which requires nothing is attached to the first trunk level instead of
                  floating free, so that it still has a place in the tree and the second level
                  still waits for it. Setting this to an empty list explicitly opts out.
                '';
              };

              user = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                description = ''
                  The user this unit runs as.
                '';
              };

              group = lib.mkOption {
                type = with lib.types; nullOr str;
                default = null;
                description = ''
                  The group this unit runs as.
                '';
              };

              environment = lib.mkOption {
                type = with lib.types; attrsOf str;
                default = { };
                example = {
                  TZ = "CET";
                };
                description = ''
                  Environment variables passed to this unit's process.
                '';
              };

              startTimeout = lib.mkOption {
                type = with lib.types; nullOr ints.unsigned;
                default = null;
                description = ''
                  How long, in seconds, this unit may take to become ready before it is
                  considered failed. Subject to
                  {option}`providers.services.supportedFeatures.startTimeout`.
                '';
              };

              stopTimeout = lib.mkOption {
                type = with lib.types; nullOr ints.unsigned;
                default = null;
                description = ''
                  How long, in seconds, this unit is given to exit after being asked to stop,
                  before it is killed outright. Subject to
                  {option}`providers.services.supportedFeatures.stopTimeout`.

                  Implementation defaults are chosen for units which exit promptly and are
                  usually only a few seconds. Anything which flushes state on the way out - a
                  database especially - should say so here rather than be killed mid-write.
                '';
              };
            };

            config = {
              description = lib.mkDefault name;
            };
          }
        )
      );
    };

  };

  config = {
    warnings = lib.optionals (cfg.units != { } && cfg.backend == "none") [
      ''
        no services provider backend has been enabled, yet the following units are defined:
        ${lib.concatStringsSep ", " (lib.attrNames cfg.units)}
        select a backend implementation to use these units
      ''
    ];

    assertions = [
      {
        assertion = danglingEdges == [ ];
        message = ''
          providers.services units require units which are not defined:
          ${lib.concatStringsSep "\n" danglingEdges}
        '';
      }

      {
        assertion = scan.cycle == null;
        message = ''
          providers.services units form a dependency cycle, so none of them could ever start:
          ${lib.concatStringsSep " -> " (scan.cycle or [ ])}
        '';
      }
    ]
    ++ lib.mapAttrsToList (name: unit: {
      assertion = unit.type == "anchor" -> unit.command == null;
      message = "providers.services.units.${name} is an anchor, and so must not set a command";
    }) cfg.units
    ++ lib.mapAttrsToList (name: unit: {
      assertion = unit.type != "anchor" -> unit.command != null;
      message = "providers.services.units.${name} is a ${unit.type}, and so must set a command";
    }) cfg.units
    ++ lib.mapAttrsToList (name: unit: {
      assertion = (unit.type == "service" && unit.readiness == "pidfile") -> unit.pidFile != null;
      message = "providers.services.units.${name} reports readiness by pidfile, and so must set pidFile";
    }) cfg.units
    ++ lib.mapAttrsToList (name: unit: {
      assertion =
        (unit.startTimeout != null && cfg.backend != "none") -> cfg.supportedFeatures.startTimeout;
      message = ''
        providers.services.units.${name} sets a startTimeout, but the ${cfg.backend} backend cannot
        bound unit startup. Remove it, or accept that a unit which never becomes ready stalls
        everything requiring it.
      '';
    }) cfg.units
    ++ lib.mapAttrsToList (name: unit: {
      assertion =
        (unit.stopTimeout != null && cfg.backend != "none") -> cfg.supportedFeatures.stopTimeout;
      message = ''
        providers.services.units.${name} sets a stopTimeout, but the ${cfg.backend} backend cannot
        bound how long a unit takes to stop.
      '';
    }) cfg.units
    ++ lib.mapAttrsToList (
      name: unit:
      let
        attached = lib.filter (dep: lib.elem dep cfg.trunk.levels) unit.requires;
      in
      {
        assertion = lib.length attached < 2;
        message = ''
          providers.services.units.${name} requires more than one trunk level: ${lib.concatStringsSep ", " attached}
          A unit attaches to exactly one level. Requiring two also makes the later level require
          this unit, by way of the earlier one, which is a cycle.
        '';
      }
    ) (lib.filterAttrs (name: _: !(lib.elem name cfg.trunk.levels)) cfg.units);
  };
}
