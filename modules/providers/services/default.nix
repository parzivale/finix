{
  config,
  pkgs,
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

  # `program` admits a command with arguments as well as a bare path - runit has no poweroff
  # binary of its own and reaches its init as `runit-init 0` - so these are exec shims rather
  # than symlinks, which could only name a file.
  shutdownPackage = pkgs.runCommand "services-shutdown-commands" { } (
    ''
      mkdir -p $out/bin
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: command: ''
        printf '#!%s\nexec %s "$@"\n' \
          ${lib.escapeShellArg pkgs.runtimeShell} ${lib.escapeShellArg command} > $out/bin/${name}
        chmod +x $out/bin/${name}
      '') cfg.shutdownCommands
    )
  );

  # a unit's readiness kind, written the way supportedFeatures.readiness names it: the tag,
  # except that a waitFor is qualified by which of its kinds it is, since an implementation may
  # have a mechanism for one and nothing for another.
  readinessNameOf =
    unit:
    let
      readiness = unit.type.service.readiness;
      kind = lib.head (lib.attrNames readiness);
    in
    if kind == "waitFor" then "waitFor.${lib.head (lib.attrNames readiness.waitFor)}" else kind;

  unsupportedReadiness =
    unit: unit.type ? service && !(lib.elem (readinessNameOf unit) cfg.supportedFeatures.readiness);

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

      # Nothing here describes how an implementation does something - only what it will refuse
      # or fail to honour. `nativeAnchors` and `nativeStartOnlyEdges` used to sit here and did
      # neither: an anchor and a start-only edge are part of the contract's vocabulary and are
      # always available, natively on the implementations which have them and emulated on the
      # ones which do not, with identical behaviour either way. A flag nothing reads, for a
      # difference nothing can observe, is a worse thing to carry than the emulation.
      readiness = lib.mkOption {
        type = lib.types.listOf (
          lib.types.enum [
            "fork"
            "notify"
            "s6"
            "waitFor.socket"
            "waitFor.pidfile"
            "waitFor.path"
            "waitFor.check"
          ]
        );
        description = ''
          Every readiness kind the selected {option}`providers.services` implementation can
          observe, named as it is tagged in {option}`providers.services.units.<name>.type`.

          A kind absent from this list cannot be honoured, and asking for one is refused.

          This lists the whole vocabulary rather than only the protocols needing the daemon's
          cooperation, because the ones that do not are not universally available either.
          `waitFor.pidfile` says the daemon forks and the process which was spawned exits;
          `runsv` and `s6-supervise` read that exit as a crash and restart it forever, so on
          those two it cannot work at all - where finit and dinit both watch it natively.
          Listing only `notify` and `s6` left that unsayable, and so unrefused.
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

    shutdownCommands =
      let
        mkCommand =
          name: what:
          lib.mkOption {
            type = program;
            internal = true;

            # same reasoning as initExecutable: the module system's own error for an option with
            # no value names the option rather than the configuration mistake behind it
            default = throw ''
              providers.services.backend is "${cfg.backend}", which declares no way to ${what}.

              Bringing the machine down is PID 1's job, so the module selected as the backend is
              expected to set providers.services.shutdownCommands.${name} to whichever of its
              binaries does it. Either that module does not implement the whole contract yet, or
              no backend was selected and this machine has nothing to bring down.
            '';

            description = "The command which asks PID 1 to ${what}.";
          };
      in
      {
        poweroff = mkCommand "poweroff" "power the machine off";
        reboot = mkCommand "reboot" "reboot the machine";
        halt = mkCommand "halt" "halt the machine";
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

                        There are two sorts here, and the difference is who decides.

                        `notify` and `s6` are the daemon saying so - an `sd_notify` `READY=1`
                        on the notification socket, or an `s6` notification on a descriptor.
                        Both need the program's cooperation, so an implementation may not be
                        able to observe them and will refuse them rather than downgrade.

                        `waitFor` is the supervisor inferring it from something appearing: a
                        pid file, a socket, any path. That works with a program which cannot
                        report anything, which is most of them, and every implementation can
                        do it - by its own mechanism where it has one, by polling otherwise.
                        It is inference rather than assertion: a unix socket's path exists
                        from `bind`, which is fractionally before `listen`.

                        `fork` treats the unit as ready the moment it has been forked. That is
                        a lie for anything doing real startup work, and is worth reaching for
                        only when nothing appears that could be waited on.
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

                          waitFor = lib.mkOption {
                            description = ''
                              Ready once something appears and is live, for a daemon with no
                              readiness protocol of its own - which is most of them.

                              The tag says what is being waited for, and so what counts as
                              live. An implementation reaches for a native mechanism where it
                              has one for that kind, and polls otherwise. This is inference
                              rather than assertion, which is why it is not `notify` or `s6`.
                            '';

                            type = lib.types.attrTag {
                              socket = lib.mkOption {
                                description = ''
                                  Ready once connecting to the socket succeeds.

                                  Not merely that the path is there: a unix socket exists from
                                  `bind`, and `listen` comes afterwards, so a client arriving
                                  in that window is refused by a socket which demonstrably
                                  exists.
                                '';
                                type = lib.types.submodule {
                                  options.path = lib.mkOption {
                                    type = lib.types.str;
                                    example = "/run/dbus/system_bus_socket";
                                    description = "The socket this unit binds.";
                                  };
                                };
                              };

                              pidfile = lib.mkOption {
                                description = ''
                                  Ready once the file exists and the process it names is alive.

                                  This also says the daemon forks into the background to write
                                  it, which finit and dinit observe directly. A program which
                                  stays in the foreground and happens to write a pid file is
                                  not this - it is `path` - and an implementation waiting for a
                                  fork which never comes will fail the unit on its start
                                  timeout.
                                '';
                                type = lib.types.submodule {
                                  options.file = lib.mkOption {
                                    type = lib.types.str;
                                    example = "/run/nginx.pid";
                                    description = "The file the daemon writes its process ID to.";
                                  };
                                };
                              };

                              path = lib.mkOption {
                                description = ''
                                  Ready once the path exists, which is all that can be known
                                  about an arbitrary file.
                                '';
                                type = lib.types.submodule {
                                  options.path = lib.mkOption {
                                    type = lib.types.str;
                                    example = "/run/something.ready";
                                    description = "The path to wait for.";
                                  };
                                };
                              };

                              check = lib.mkOption {
                                description = ''
                                  Ready once this command exits successfully.

                                  The command does the waiting - it is run once, and returning
                                  is what says the unit is up - so anything whose readiness only
                                  it can answer belongs here: a database accepting queries, an
                                  endpoint returning 200. The other kinds are the common cases
                                  of this one, written out so they need no script.

                                  A command which never returns stalls everything behind the
                                  unit until {option}`startTimeout`, where the implementation
                                  can bound it. It is the script's business to give up.
                                '';
                                type = lib.types.submodule {
                                  options.command = lib.mkOption {
                                    type = program;
                                    example = lib.literalExpression ''
                                      pkgs.writeShellScript "pg-ready" '''
                                        until pg_isready -q; do sleep 0.1; done
                                      '''
                                    '';
                                    description = "The command whose successful exit means ready.";
                                  };
                                };
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
                # the trunk's own levels are excluded: a level derives its own requires from
                # the chain, and defaulting it to the head would make the first level require
                # itself
                default = lib.optional (!(lib.elem name cfg.trunk.levels)) (lib.head cfg.trunk.levels);
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

    # switching between init systems is not something a switch can do. Everything else in a
    # generation can be replaced while the machine runs, but PID 1 is the one process that
    # cannot: the kernel started it, `switch-to-configuration` has no way to hand the machine to
    # another, and the supervisor that ends up running the new generation's units would be the
    # old init with none of the new one's state. The result is a machine whose services are
    # described by one implementation and supervised by another.
    #
    # So this is a reboot, and the inhibitor says so rather than letting the switch half-happen.
    #
    # The backend's name, not initExecutable: the executable is a generated wrapper carrying the
    # activation script - and, on dinit, the unit fingerprints - so it changes whenever anything
    # does, and an inhibitor which fires on every switch is one nobody reads.
    system.switch.inhibitors.init = cfg.backend;

    # the other half of being PID 1. Every implementation ships binaries under these names, and
    # each one talks only to its own init - finit's poweroff asks finit, over finit's socket -
    # so on a machine running any other backend the wrong one is a command which reports a
    # failure and leaves the machine running.
    #
    # Which one a bare `poweroff` reaches is otherwise a question of which package buildEnv
    # happens to walk first, because environment.path ignores collisions. hiPrio settles it on
    # the selected backend's, rather than on whichever module was imported first.
    environment.systemPackages = [ (lib.hiPrio shutdownPackage) ];

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
      # readiness is not here: an unobservable kind is refused outright, in assertions below.
      ++ lib.optionals (cfg.backend != "none") (
        lib.optionals (!cfg.supportedFeatures.user) (
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
    ) (lib.filterAttrs (name: _: !(lib.elem name cfg.trunk.levels)) cfg.units)

    # a readiness kind the implementation cannot observe is refused rather than warned about,
    # which is what supportedFeatures.readiness has always said would happen. Every other
    # unhonoured capability leaves the unit behaving as though it had not been asked for;
    # these do not. Unobserved, `notify` and `s6` mean a unit reported ready the moment it was
    # spawned, and everything behind it starts too early. `waitFor.pidfile` is worse: the
    # daemon forks, the spawned process exits, and a supervisor which cannot expect that
    # restarts it forever.
    ++ lib.optionals (cfg.backend != "none") (
      lib.mapAttrsToList (name: unit: {
        assertion = false;
        message = ''
          providers.services.units.${name} reports readiness by ${readinessNameOf unit}, which
          the ${cfg.backend} implementation cannot observe.

          It observes: ${lib.concatStringsSep ", " cfg.supportedFeatures.readiness}
        '';
      }) (lib.filterAttrs (_: unsupportedReadiness) cfg.units)
    );
  };
}
