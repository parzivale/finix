# every module, on every implementation, evaluated
#
# The provider suite proves the contract works. This proves the modules *use* it - which is a
# different question, and the one that goes wrong quietly: a unit requiring a name nothing
# defines, asking for a readiness its backend cannot observe, attaching to two trunk levels, or
# forming a cycle. None of that needs a machine to detect. All of it is refused at evaluation,
# by assertions the contract already makes, and until now nothing forced that evaluation for
# anything but the handful of modules the VM tests happen to enable.
#
# 120 modules against 5 implementations is 600 checks. As VM tests that is a day; as
# evaluations it is minutes, because each one only has to build a configuration and read its
# assertions back - no kernel, no image, no boot.
#
# What it does not catch is behaviour: a daemon which starts and does not work, a readiness
# which is declared and not spoken. That is what the provider matrix is for, and why this does
# not replace it.
{
  lib,
  pkgs,
  ...
}:
let
  testLib = import ../lib { inherit lib pkgs; };

  backends = [
    "finit"
    "dinit"
    "runit"
    "s6-rc"
    "sinit"
  ];

  # the option which turns each module on, derived from where it lives rather than guessed:
  # modules/services/foo is services.foo, modules/programs/bar is programs.bar
  modulesIn =
    kind:
    lib.filter (n: n != "README.md") (
      lib.attrNames (
        lib.filterAttrs (_: t: t == "directory") (builtins.readDir (../../modules + "/${kind}"))
      )
    );

  # a directory is named after its option nearly always; where it is not, this says so. The
  # mismatch is otherwise silent - the path does not exist, `optional` reads that as "nothing
  # to turn on", and the module is quietly never checked at all.
  optionName = {
    chronyd = "chrony";
  };

  enableOf = name: optionName.${name} or name;

  # a machine with one module turned on and nothing else to distract from it
  nodeFor =
    kind: name: backend:
    {
      modules,
      ...
    }:
    {
      # `imports` cannot come from inside an mkMerge, so it stays at the top level and the
      # computed option path is merged into `config` beneath it
      imports = lib.optional (backend != "finit") modules.${backend};

      config = lib.mkMerge [
        {
          providers.services.backend = backend;

          # finix asserts a terminal exists when finit is PID 1, and a device manager is close
          # enough to universal that a machine without one is not the thing being tested here
          services.getty.enable = true;
          services.mdevd.enable = true;
        }

        # `setAttrByPath` rather than a literal: which option turns the module on is computed
        # from where it lives, and Nix takes a dynamic attribute name but not a dynamic path
        (lib.setAttrByPath [ kind (enableOf name) "enable" ] true)
      ];
    };

  # what the module turned out to say, or why asking failed. `tryEval` because a module which
  # throws - a missing required option, an assertion in its own code - should be one failing
  # check rather than something which takes the whole attribute set down with it.
  verdict =
    kind: name: backend:
    let
      # everything is forced *inside* the tryEval. Left lazy, the failure escapes it and lands
      # wherever the value is finally used - which was the derivation's own buildCommand, so a
      # module which could not be evaluated took the check for it down rather than failing it.
      attempt = builtins.tryEval (
        let
          cfg = (testLib.evalNode "machine" (nodeFor kind name backend)).config;

          # a unit set which is never looked at is one whose edges are never checked - and the
          # edges alone are not enough of a look. A module writing an integer into
          # `environment`, which is `attrsOf str`, is a type error the module system raises
          # when that value is demanded and never before: forcing only `requires` meant
          # services.accounts-daemon passed this check for as long as it existed, and failed
          # the first time a machine was actually built from it.
          #
          # Everything cheap is forced. Not `type`, whose command may be a derivation whose
          # own attributes are derivations - that is the deep-forcing the portedness check
          # below has to avoid to stay inside the evaluator.
          units = lib.mapAttrs (_: u: {
            inherit (u)
              requires
              environment
              user
              group
              ;

            # both hold paths, which may be derivations - and a derivation deep-forced is its
            # own attributes deep-forced, which is the stack overflow this check exists to
            # survive rather than cause. The string is what matters here anyway: it is what
            # the fingerprint hashes.
            path = map toString u.path;
            reloadTriggers = map toString u.reloadTriggers;
          }) cfg.providers.services.units;
          messages = map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
        in
        lib.deepSeq units (lib.deepSeq messages messages)
      );
    in
    if attempt.success then attempt.value else [ "evaluation failed" ];

  # what a machine looks like with nothing extra turned on, so that what a module adds can be
  # told from what was already there
  # measured on dinit, not on finit.
  #
  # On finit a contract unit *is* a finit stanza - the backend generates one for every unit -
  # so "did enabling this add stanzas" is true whether the module was ported or not. On any
  # other backend the finit module's own config is switched off, so the only stanzas left are
  # the ones a module wrote by hand, which is exactly the thing being looked for.
  baseline = lib.mapAttrs (_: node: (testLib.evalNode "machine" node).config) {
    dinit = nodeFor "services" "getty" "dinit";
  };

  stanzaNames =
    cfg:
    lib.concatMap (attr: lib.attrNames (cfg.finit.${attr} or { })) [
      "services"
      "tasks"
      "run"
    ];

  # the same question for tmpfiles, which are a list and so have no names to subtract.
  #
  # `finit.tmpfiles.rules` is finit's own tmpfiles.d(5) reader, and a module writing rules
  # there gets its directories on finit and on nothing else - the same bug as a stanza, in a
  # place the name-based check above cannot see.
  tmpfilesRules = cfg: lib.length (cfg.finit.tmpfiles.rules or [ ]);

  # and for the restart triggers, which hide in /etc rather than in an option.
  #
  # `environment.etc."finit.d/<name>.conf".text = lib.mkAfter "# <config path>"` is the trick
  # for making finit notice that a daemon's configuration changed: the stanza file gains the
  # path, so the stanza differs, so finit restarts it. It reaches finit alone - on any other
  # implementation a changed config file leaves the daemon running with the old one, and
  # nothing says so. The contract's own version of the trick is to name the path inside the
  # unit's command, where every implementation's fingerprint will see it.
  restartTriggers =
    cfg: lib.filter (lib.hasPrefix "finit.d/") (lib.attrNames (cfg.environment.etc or { }));

  # a module is ported when turning it on adds contract units rather than finit stanzas.
  #
  # This is the check the per-backend one cannot make: an unported module is not *broken* on
  # dinit, it is absent - its stanzas are written into a configuration nothing reads, and the
  # daemon simply never exists. Nothing asserts, nothing warns, and the only symptom is a
  # machine missing a service somebody thought they had enabled.
  portedness =
    kind: name:
    let
      attempt = builtins.tryEval (
        let
          cfg = (testLib.evalNode "machine" (nodeFor kind name "dinit")).config;

          # the names and the count, and nothing else. `deepSeq` on `cfg.finit` itself would
          # force every stanza's command - which is a package, whose own attributes are
          # packages - and run the evaluator out of stack before it got to the question.
          result = {
            stanzas = lib.subtractLists (stanzaNames baseline.dinit) (stanzaNames cfg);
            rules = tmpfilesRules cfg - tmpfilesRules baseline.dinit;
            triggers = lib.subtractLists (restartTriggers baseline.dinit) (restartTriggers cfg);
          };
        in
        lib.deepSeq result result
      );
    in
    if !attempt.success then
      [ ] # whatever is wrong with it, the per-backend checks will say so
    else
      lib.optional (attempt.value.stanzas != [ ])
        "adds finit stanzas rather than contract units, so it exists on finit and nowhere else: ${lib.concatStringsSep ", " attempt.value.stanzas}"
      ++
        lib.optional (attempt.value.rules > 0)
          "adds ${toString attempt.value.rules} rules to finit.tmpfiles.rules rather than providers.services.tmpfiles.rules, so the paths it needs are created on finit and nowhere else"
      ++
        lib.optional (attempt.value.triggers != [ ])
          "writes a restart trigger into ${lib.concatStringsSep ", " attempt.value.triggers}, so a changed configuration restarts the daemon on finit and is ignored everywhere else - name the config path in the unit's own command instead";

  check =
    kind: name: backend:
    let
      messages = verdict kind name backend ++ lib.optionals (backend == "finit") (portedness kind name);
    in
    pkgs.runCommand "check-${kind}-${name}-${backend}" { } (
      if messages == [ ] then
        "touch $out"
      else
        ''
          echo "${kind}.${name} on ${backend}:" >&2
          ${lib.concatMapStringsSep "\n" (m: "echo ${lib.escapeShellArg m} >&2") messages}
          exit 1
        ''
    );

  # modules which cannot be turned on without being told something first, and so cannot be
  # checked by turning them on. Each is named with what it wants, because the alternative -
  # treating every evaluation failure as "needs configuration" - would have hidden the two real
  # ones this check found on its first run.
  needsConfiguration = {
    sshguard = "settings.FILES, the logs to watch";

    # `user` and `command` have no default, and it asserts that a seat manager exists - all
    # three correctly, which is why turning it on alone cannot work
    autologin = "a user, a command, and a seat manager";

    # `package` has no default: which major version a cluster is created with is not something
    # to pick on somebody's behalf, since moving between them means a dump and a restore
    postgresql = "package, the major version to run";

    # each drives a driver rather than installing one, and each asserts as much
    nvidia-settings = "hardware.nvidia.enable, the driver it configures";
    nvidia-persistenced = "hardware.nvidia.enable, the driver it keeps loaded";
    nvidia-powerd = "hardware.nvidia.enable, the driver it manages power for";

    # keventd is finit's own device event daemon, and the version of it this module drives has
    # not been released yet - the assertion is the module's, and it is right
    keventd = "a finit of at least 5.0, which nixpkgs does not have yet";
  };

  # a module with no `enable` is one a machine always has - coreutils, modprobe, the shell -
  # and there is nothing to turn on and therefore nothing here to check
  optional =
    kind: name:
    lib.hasAttrByPath [
      kind
      (enableOf name)
      "enable"
    ] (testLib.evalNode "machine" (nodeFor "services" "getty" "finit")).options;

  checksFor =
    kind:
    lib.listToAttrs (
      map (
        name: lib.nameValuePair name (lib.recurseIntoAttrs (lib.genAttrs backends (check kind name)))
      ) (lib.filter (name: optional kind name && !(needsConfiguration ? ${name})) (modulesIn kind))
    );
in
{
  services = lib.recurseIntoAttrs (checksFor "services");
  programs = lib.recurseIntoAttrs (checksFor "programs");
}
