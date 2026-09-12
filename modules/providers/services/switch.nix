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
        builtins.toJSON (
          {
            # `type` now carries the command and readiness of whichever kind this is, so it
            # covers on its own what three separate fields used to
            inherit (unit)
              type
              user
              group
              environment
              startTimeout
              stopTimeout
              ;
            path = map toString unit.path;
          }

          # an anchor's edges are deliberately not part of what it is.
          #
          # A trunk level requires the level before it and everything attached to that level,
          # so adding or removing any unit anywhere changes the `requires` of every level
          # downstream of it. Were that in the fingerprint, one new unit would mark half the
          # trunk as changed and the engine would stop and restart it - which accomplishes
          # nothing, because an anchor has no process to restart, and on s6-rc is destructive:
          # dependencies there are hard, so bringing a level down brings down everything above
          # it, including the units the switch was supposed to leave alone.
          #
          # What an anchor is, is its existence. Added or removed it is started or stopped;
          # otherwise there is nothing about it to change.
          // lib.optionalAttrs (!(unit.type ? anchor)) { inherit (unit) requires; }
        )
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

  # the units which said they can re-read their own configuration, and the commands which make
  # them do it. Two files rather than one, because the engine wants the names sorted for
  # `comm` and the commands addressed by name.
  reloadable = lib.filterAttrs (_: u: (u.type.service.reload or null) != null) enabled;

  reloadableNames = pkgs.writeText "services-reloadable" (
    lib.concatMapStringsSep "\n" (n: n) (lib.sort (a: b: a < b) (lib.attrNames reloadable)) + "\n"
  );

  reloadCommands = pkgs.runCommand "services-reload-commands" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (name: unit: ''
        printf '#!%s\nexec %s\n' \
          ${lib.escapeShellArg pkgs.runtimeShell} ${lib.escapeShellArg unit.type.service.reload} > $out/${name}
        chmod +x $out/${name}
      '') reloadable
    )
  );

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
      # only in current, its new pair only in incoming.
      comm -13 "$work/incoming" "$work/current" | cut -f1 > "$work/gone"
      comm -23 "$work/incoming" "$work/current" | cut -f1 | sort > "$work/arrived"

      # which of those are the same unit changed, rather than one removed and another added:
      # the name is on both sides.
      comm -12 "$work/gone" <(sort "$work/arrived") | sort > "$work/changed"

      # a changed unit which says it can re-read its own configuration is reloaded rather than
      # stopped and started. Whether that is enough is the unit's claim, not something which
      # can be worked out from here - see the `reload` option.
      comm -12 "$work/changed" "${reloadableNames}" > "$work/reload"

      # everything else moves the usual way. A reloaded unit is in neither list: it is not
      # stopped, so it keeps its pid, which is the whole point of reloading it.
      comm -23 "$work/gone" "$work/reload" > "$work/stop"
      comm -23 "$work/arrived" "$work/reload" > "$work/start-set"

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

      # last, and not through the implementation: a reload is the unit's own command, run
      # against a process which is already there. Nothing about it is the supervisor's
      # business, which is why this needs no fourth operation from the backends.
      if [ -s "$work/reload" ]; then
        echo "reloading: $(tr '\n' ' ' < "$work/reload")"
        while read -r unit; do
          if ! "${reloadCommands}/$unit"; then
            echo "  reload of $unit failed" >&2
          fi
        done < "$work/reload"
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
