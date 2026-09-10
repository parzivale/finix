{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  # what makes a unit "the same unit, changed" rather than a different one. taken over the
  # contract's own definition, so it means the same thing on every init system - a backend
  # altering how it emits a unit does not by itself count as the unit having changed.
  #
  # the engine computes this for the incoming tree, and the backend carries it through into
  # whatever configuration it writes so that `list` can hand it back. that way the engine
  # compares two numbers it produced itself, and never needs to know how an init stores things.
  fingerprintOf =
    unit:
    builtins.substring 0 16 (
      builtins.hashString "sha256" (
        builtins.toJSON {
          inherit (unit)
            type
            command
            readiness
            pidFile
            requires
            user
            group
            environment
            startTimeout
            stopTimeout
            ;
          path = map toString unit.path;
        }
      )
    );

  # activation order is a topological sort: the post-order walk emits a unit only once
  # everything it requires has been emitted, which is exactly the order they may be started in.
  # cycles are refused by an assertion in the contract, so this cannot run away.
  #
  # there is deliberately no equivalent for deactivation. dependencies gate starting only, so
  # nothing is ever waiting for anything else to stop, and units may be torn down in any order.
  order =
    let
      visit =
        acc: name:
        if lib.elem name acc.seen then
          acc
        else
          let
            deps = lib.filter (d: enabled ? ${d}) (enabled.${name}.requires or [ ]);
            inner = lib.foldl visit (acc // { seen = acc.seen ++ [ name ]; }) deps;
          in
          inner // { out = inner.out ++ [ name ]; };
    in
    (lib.foldl visit {
      seen = [ ];
      out = [ ];
    } (lib.attrNames enabled)).out;

  # the incoming tree, in the same shape `list` reports the running one
  incoming = pkgs.writeText "services-incoming" (
    lib.concatMapStringsSep "\n" (name: "${name}\t${fingerprintOf enabled.${name}}") order
  );

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  sw = cfg.switch;

  engine = pkgs.writeShellApplication {
    name = "providers-services-switch";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      # reconcile the running system against the incoming one.
      #
      # the provider supplies three things and no more: `list`, reporting what is running in a
      # form comparable with the incoming tree, and `activate` / `deactivate`, each taking unit
      # names on stdin. everything below is the same for every init system.

      incoming=${incoming}
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      sort "$incoming" > "$work/incoming"
      ${sw.list} | sort > "$work/current"

      # a unit whose definition changed appears on both sides - its old name/fingerprint pair
      # only in current, its new pair only in incoming - so it is stopped and started again
      # without needing a category of its own.
      comm -13 "$work/incoming" "$work/current" | cut -f1 > "$work/stop"
      comm -23 "$work/incoming" "$work/current" | cut -f1 | sort > "$work/start-set"

      # `incoming` is in dependency order, so filtering it rather than the sorted set keeps
      # activations ordered after whatever they require. done via a file rather than a pipe:
      # grep may close its input early, and the resulting SIGPIPE would surface as a spurious
      # error under `pipefail`.
      cut -f1 "$incoming" > "$work/ordered"
      grep -xF -f "$work/start-set" "$work/ordered" > "$work/start" || true

      # order is irrelevant on the way down: dependencies gate starting only, so nothing is
      # ever waiting for another unit to stop
      if [ -s "$work/stop" ]; then
        echo "stopping: $(tr '\n' ' ' < "$work/stop")"
        ${sw.deactivate} < "$work/stop" || echo "  deactivation reported a failure" >&2
      fi

      if [ -s "$work/start" ]; then
        echo "starting: $(tr '\n' ' ' < "$work/start")"
        ${sw.activate} < "$work/start" || echo "  activation reported a failure" >&2
      fi
    '';
  };
in
{
  options.providers.services.switch = {
    list = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        A program printing every unit the implementation currently has active, one per line,
        as a name and a fingerprint separated by a tab.

        The fingerprint is the one the implementation was given when the unit was written, and
        is only ever compared for equality - it is opaque to the implementation and means
        nothing to it.

        An implementation which reconciles from its own configuration may print nothing. Every
        unit is then reported as new, {option}`activate` is handed the whole tree, and that
        implementation's own reconciliation does the work.
      '';
    };

    activate = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        A program reading unit names on standard input, one per line, and starting them.

        Names arrive in dependency order, so acting on them in the order given starts each
        unit after everything it requires. An implementation which reconciles from its own
        configuration may ignore the names entirely and simply reload.
      '';
    };

    deactivate = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      description = ''
        A program reading unit names on standard input, one per line, and stopping them.

        No order is specified, and none is needed: dependencies gate starting only, so nothing
        is ever waiting for another unit to stop.
      '';
    };

    fingerprints = lib.mkOption {
      type = with lib.types; attrsOf str;
      internal = true;
      readOnly = true;
      description = ''
        Each unit's fingerprint, for the implementation to carry through into whatever
        configuration it writes so that {option}`list` can report it back.
      '';
    };

    supported = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      readOnly = true;
      description = ''
        Whether the selected implementation supplies all three operations, and so whether a
        running system can be reconciled against a new one.
      '';
    };
  };

  config = {
    providers.services.switch.fingerprints = lib.mapAttrs (_: fingerprintOf) enabled;

    providers.services.switch.supported =
      sw.list != null && sw.activate != null && sw.deactivate != null;

    # empty rather than absent when unsupported, so switch-to-configuration can substitute it
    # unconditionally and simply skip the step
    system.build.servicesSwitch = if cfg.switch.supported then lib.getExe engine else "";

    warnings = lib.optional (cfg.units != { } && cfg.backend != "none" && !cfg.switch.supported) ''
      the ${cfg.backend} services provider does not supply list/activate/deactivate, so
      switching cannot reconcile units and will fall back to whatever that implementation
      does on its own.
    '';
  };
}
