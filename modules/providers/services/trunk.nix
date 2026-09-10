{
  config,
  lib,
  ...
}:
let
  cfg = config.providers.services.trunk;
  units = config.providers.services.units;

  indexOf =
    name:
    let
      hits = lib.imap0 (i: l: if l == name then i else null) cfg.levels;
    in
    lib.findFirst (i: i != null) null hits;

  latchIndex = indexOf cfg.latch;

  # the units which attached themselves to a level, found by reading the graph backwards. this
  # is what makes the chain advance: a level is not reached until everything at the previous
  # level is up, exactly as a runlevel is not entered until the previous one has finished.
  dependants =
    level:
    lib.attrNames (
      lib.filterAttrs (name: unit: !(lib.elem name cfg.levels) && lib.elem level unit.requires) units
    );

  mkLevel =
    i: level:
    let
      previous = lib.elemAt cfg.levels (i - 1);
    in
    {
      type = "anchor";
      description = "trunk level ${level}";

      # the latch is the one level the graph cannot derive. it means "every unit before it has
      # stopped", which is not a fact about starting and so has no edge to hang on - the backend
      # supplies it, by emitting the latch where its init system signals shutdown.
      requires = if i == 0 || i == latchIndex then [ ] else [ previous ] ++ dependants previous;
    };
in
{
  options.providers.services.trunk = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to define the trunk: a chain of process-less units which every other unit can
        rely on being present, and which stands in for the runlevels of a traditional init
        system.

        A level is somewhere to attach, not a barrier. It gives a unit with no natural
        predecessor a place in the tree, and it orders the tiers coarsely - units attached to
        one level start once the units attached to the previous level are up. It does not
        promise that any particular subsystem is working, because a level only waits for the
        units which named it, not for whatever chains off those units. Anything which genuinely
        needs a subsystem must require that subsystem's unit directly.

        Units attach by requiring exactly one level, and never by being named from the trunk,
        so the chain's shape is fixed here and cannot drift as modules accumulate.
      '';
    };

    levels = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "start"
        "sysinit"
        "basic"
        "multi-user"
        "running"
        "stopped"
        "shutdown"
      ];
      description = ''
        The trunk, in order. Each entry becomes an `anchor` unit requiring the previous level
        and everything attached to it.

        A level is named for the tier it marks the completion of, not the tier which attaches
        to it: units attached to `sysinit` are the basic tier, and once they are up, `basic` is
        reached. So the first level exists only to be attached to - `start` marks nothing,
        because nothing has happened yet - and the last boot level, `running`, marks the whole
        userspace being up and has nothing attached to it.

        Levels at or after {option}`latch` are the shutdown sequence: they cannot be reached
        while the system is running, so units attached to them run on the way down.

        ::: {.note}
        A level becomes a unit name in the selected backend, so it must not collide with a
        name that backend reserves. `boot` is unusable for this reason: it is `dinit`'s own
        root service, and a trunk level of that name would overwrite it.
        :::
      '';
    };

    latch = lib.mkOption {
      type = lib.types.str;
      default = "stopped";
      description = ''
        The one level which does not resolve during normal operation.

        Everything before it is the boot sequence. The latch itself is reached only once every
        unit before it has stopped, which only happens when the system is going down - so
        everything after it is the shutdown sequence, ordered by the same chain, and a unit
        which needs to run on the way out attaches to a level after the latch rather than
        needing a concept of its own.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    providers.services.units = lib.listToAttrs (
      lib.imap0 (i: level: lib.nameValuePair level (mkLevel i level)) cfg.levels
    );

    assertions = [
      {
        assertion = lib.elem cfg.latch cfg.levels;
        message = ''
          providers.services.trunk.latch is set to "${cfg.latch}", which is not one of the
          trunk levels: ${lib.concatStringsSep ", " cfg.levels}
        '';
      }

      {
        assertion = cfg.levels == lib.unique cfg.levels;
        message = ''
          providers.services.trunk.levels contains a repeated level, so the chain's order is
          ambiguous: ${lib.concatStringsSep ", " cfg.levels}
        '';
      }
    ];
  };
}
