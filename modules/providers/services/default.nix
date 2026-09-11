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
  imports = [
    ./activation.nix
    ./mounts.nix
    ./switch.nix
    ./tmpfiles.nix
    ./trunk.nix
    ./users.nix
  ];

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

      readiness = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "fork"
            "pidfile"
            "notify"
            "s6"
          ]
        );
        description = ''
          The ways the selected {option}`providers.services` implementation can observe a unit
          becoming ready.

          A kind absent from this list cannot be honoured, and asking for one is refused rather
          than quietly downgraded to `fork` - which would report a unit ready the moment it was
          spawned and start everything behind it too early.
        '';
      };

      user = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can run a unit as a
          given user. An implementation which cannot must say so, since the alternative is
          running as `root` something which asked not to be.
        '';
      };

      group = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can run a unit under
          a given group.
        '';
      };

      path = lib.mkOption {
        type = lib.types.bool;
        description = ''
          Whether the selected {option}`providers.services` implementation can give a unit its
          own `PATH`. Where it cannot, a unit's command must name everything it runs absolutely.
        '';
      };
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "none" ];
      default = "none";
      description = ''
        The selected module which should implement functionality for the {option}`providers.services` contract.

        This is PID 1 as well as the supervisor: the module named here points
        {option}`boot.init` at its own executable. The two are not separable, because an init
        is not only a thing which supervises units - it is also what the kernel hands the
        machine to. An implementation which cannot be that is not selectable here.
      '';
    };

    initExecutable = lib.mkOption {
      type = lib.types.path;
      internal = true;

      # required, but the module system's own "accessed but has no value defined" names this
      # option rather than the thing actually wrong with the configuration
      default = throw ''
        providers.services.backend is "${cfg.backend}", which declares no PID 1 executable.

        Selecting a backend selects the init: the module named there is expected to set
        providers.services.initExecutable to whichever of its binaries the kernel should run.
        Either that module does not implement the whole contract yet, or no backend was
        selected at all and this machine has nothing to boot.
      '';

      description = ''
        The binary the kernel runs as PID 1, declared by the implementation selected in
        {option}`providers.services.backend` and pointed at {option}`boot.init` here.

        {option}`providers.services.backend` is a bare string key - each implementation unions
        its own name into the enum, and this module has never heard of any of them. So the
        key cannot be dereferenced into a package here, and the implementation answers for
        itself, exactly as it does for {option}`providers.services.supportedFeatures`.

        Which binary it is is not derivable from the name in any case: finit and dinit are
        their own inits, but runit boots through `runit-init` rather than the `runsvdir` which
        supervises, and s6 needs `s6-linux-init` in front of `s6-svscan`.
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
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether this unit is part of the system.

                  A disabled unit is not emitted at all, and is stopped on the next
                  reconciliation if it happens to be running. Units which require it are left
                  waiting, since the thing they require will never become ready - so disabling
                  a unit something else depends on is a way to stall that branch of the graph,
                  not a way to prune it.
                '';
              };

              type = lib.mkOption {
                default = {
                  service = { };
                };
                defaultText = lib.literalExpression "{ service = { }; }";
                example = lib.literalExpression ''{ service.readiness.pidfile.file = "/run/x.pid"; }'';
                description = ''
                  What kind of unit this is, and whatever that kind needs.

                  `service` is a long-running process. `oneshot` is a command which runs to
                  completion and is ready once it has exited successfully. `anchor` has no
                  process at all and is ready once its own requirements are.

                  Anchors exist to be named, so a unit can say "after the system is basically
                  up" without naming the units that means. In practice they are the trunk, and
                  ordinary modules have no reason to declare one - an interchangeable
                  implementation should be selected by a `providers.` contract and define the
                  shared unit name directly, rather than hiding behind an anchor.

                  A kind carrying nothing may be written as a bare string, so `type = "anchor"`
                  and `type = { anchor = { }; }` mean the same thing.
                '';
                type =
                  let
                    command = lib.mkOption {
                      type = program;
                      description = ''
                        The command this unit runs.
                      '';
                    };

                    readiness = lib.mkOption {
                      default = {
                        fork = { };
                      };
                      defaultText = lib.literalExpression "{ fork = { }; }";
                      description = ''
                        How this unit reports that it has become ready, and so how units
                        requiring it learn they may start.

                        `notify` waits for an `sd_notify`-style `READY=1` on the notification
                        socket, and `s6` for an `s6`-style notification on a descriptor.
                        `pidfile` waits for the daemon to background itself and write the file
                        it names. `fork` treats the unit as ready the moment it has been forked,
                        which is a lie for anything doing real startup work, but is the only
                        option left for a daemon which cannot report readiness at all.
                      '';
                      type = lib.types.coercedTo lib.types.str (kind: { ${kind} = { }; }) (
                        lib.types.attrTag {
                          fork = lib.mkOption {
                            type = lib.types.submodule { };
                            description = "Ready as soon as it has been forked.";
                          };
                          notify = lib.mkOption {
                            type = lib.types.submodule { };
                            description = "Ready on an sd_notify-style READY=1.";
                          };
                          s6 = lib.mkOption {
                            type = lib.types.submodule { };
                            description = "Ready on an s6-style notification.";
                          };

                          pidfile = lib.mkOption {
                            description = "Ready once it has backgrounded itself and written its pid.";
                            type = lib.types.submodule {
                              options.file = lib.mkOption {
                                type = lib.types.str;
                                example = "/run/nginx.pid";
                                description = ''
                                  The file this unit writes its process ID to.
                                '';
                              };
                            };
                          };
                        }
                      );
                    };
                  in
                  lib.types.coercedTo lib.types.str (kind: { ${kind} = { }; }) (
                    lib.types.attrTag {
                      service = lib.mkOption {
                        description = "A long-running process.";
                        type = lib.types.submodule { options = { inherit command readiness; }; };
                      };

                      oneshot = lib.mkOption {
                        description = "A command which runs to completion.";
                        type = lib.types.submodule { options = { inherit command; }; };
                      };

                      anchor = lib.mkOption {
                        description = "A unit with no process at all.";
                        type = lib.types.submodule { };
                      };
                    }
                  );
              };

              description = lib.mkOption {
                type = lib.types.str;
                description = ''
                  A short human-readable description of this unit.
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

              path = lib.mkOption {
                type = with lib.types; listOf (either package str);
                default = [ ];
                description = ''
                  Packages and directories placed on this unit's `PATH`.

                  Units are given a deliberately bare environment, so anything invoking a
                  program by name rather than by store path needs to say where to find it.
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
    # selecting a backend is the whole of the choice: the thing supervising the units is the
    # thing the kernel starts, so naming one here is what points stage 2 at it. No fallback -
    # a machine whose backend declares no PID 1 has no business booting.
    boot.init = cfg.initExecutable;

    warnings =
      lib.optionals (cfg.units != { } && cfg.backend == "none") [
        ''
          no services provider backend has been enabled, yet the following units are defined:
          ${lib.concatStringsSep ", " (lib.attrNames cfg.units)}
          select a backend implementation to use these units
        ''
      ]
      # a timeout the implementation cannot bound is a warning rather than a refusal: the unit
      # behaves exactly as it would had no timeout been asked for, so nothing the configuration
      # says becomes untrue - only a guard is missing. Every check below changes what the system
      # actually does, and so is refused instead.
      ++ lib.optionals (cfg.backend != "none" && !cfg.supportedFeatures.startTimeout) (
        lib.mapAttrsToList (
          name: _:
          "providers.services.units.${name} sets a startTimeout, which the ${cfg.backend} "
          + "implementation cannot bound - a unit which never becomes ready will stall "
          + "everything requiring it."
        ) (lib.filterAttrs (_: u: u.startTimeout != null) cfg.units)
      )
      ++ lib.optionals (cfg.backend != "none" && !cfg.supportedFeatures.stopTimeout) (
        lib.mapAttrsToList (
          name: _:
          "providers.services.units.${name} sets a stopTimeout, which the ${cfg.backend} "
          + "implementation cannot bound - it will be killed on whatever schedule that "
          + "implementation uses."
        ) (lib.filterAttrs (_: u: u.stopTimeout != null) cfg.units)
      )
      # every capability a unit asks for and the implementation cannot provide is reported here
      # rather than refused. The configuration still says what it meant, and the warning says
      # where it was not honoured - which keeps one unit definition usable across implementations
      # with different capabilities, instead of forcing it to be written per backend.
      #
      # `user` is the one to watch: unhonoured, the unit runs as root rather than as whoever was
      # named, which is more privilege than was asked for rather than less.
      ++ lib.optionals (cfg.backend != "none") (
        lib.mapAttrsToList
          (
            name: unit:
            let
              ready = lib.head (lib.attrNames (unit.type.service or { }).readiness or { fork = { }; });
            in
            "providers.services.units.${name} reports readiness by ${ready}, which the "
            + "${cfg.backend} implementation cannot observe (it observes "
            + "${lib.concatStringsSep ", " cfg.supportedFeatures.readiness}) - it will be treated "
            + "as ready when spawned, so anything requiring it may start too early."
          )
          (
            lib.filterAttrs (
              _: u:
              u.type ? service
              && !(lib.elem (lib.head (lib.attrNames u.type.service.readiness)) cfg.supportedFeatures.readiness)
            ) cfg.units
          )
        ++ lib.optionals (!cfg.supportedFeatures.user) (
          lib.mapAttrsToList (
            name: unit:
            "providers.services.units.${name} is to run as ${unit.user}, which the ${cfg.backend} "
            + "implementation cannot arrange - it will run as root instead."
          ) (lib.filterAttrs (_: u: u.user != null) cfg.units)
        )
        ++ lib.optionals (!cfg.supportedFeatures.group) (
          lib.mapAttrsToList (
            name: unit:
            "providers.services.units.${name} is to run under the group ${unit.group}, which the "
            + "${cfg.backend} implementation cannot arrange."
          ) (lib.filterAttrs (_: u: u.group != null) cfg.units)
        )
        ++ lib.optionals (!cfg.supportedFeatures.path) (
          lib.mapAttrsToList (
            name: _:
            "providers.services.units.${name} sets a path, which the ${cfg.backend} "
            + "implementation cannot give it - its command must name what it runs absolutely."
          ) (lib.filterAttrs (_: u: u.path != [ ]) cfg.units)
        )
      );

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
