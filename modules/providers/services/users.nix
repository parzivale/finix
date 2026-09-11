{
  config,
  options,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  # a user's unit named as the whole system sees it.
  #
  # not `@`: finit reads that as its instance separator and silently renames the stanza -
  # `agent@alice` is registered as `agent:alice` - so every condition naming it refers to
  # something which does not exist, and the unit is unreachable by the name it was given.
  # the repo's own `tlp@start` gets away with it only because nothing ever depends on it.
  scopedName = user: name: "${name}--${user}";

  # an edge naming something in the same user's tree is scoped with it; anything else is left
  # alone, and so refers to a system unit. that is what makes a user unit able to require dbus
  # or a trunk level: under this rule there is only one supervisor, so there is nothing special
  # about the edge at all.
  #
  # it is also the thing which stops being possible the moment a separate user supervisor is
  # introduced, since the two cannot see each other's state - see the assertion below.
  scopeEdge =
    user: units: dep:
    if units ? ${dep} then scopedName user dep else dep;

  flattened = lib.concatMapAttrs (
    user: u:
    lib.mapAttrs' (
      name: unit:
      lib.nameValuePair (scopedName user name) (
        (removeAttrs unit [ "_module" ])
        // {
          # the user owns the unit, so this is not the author's to set
          user = user;
          requires = map (scopeEdge user u.units) unit.requires;
        }
      )
    ) u.units
  ) cfg.users;

  crossScope = lib.concatLists (
    lib.mapAttrsToList (
      user: u:
      lib.concatLists (
        lib.mapAttrsToList (
          name: unit:
          map (dep: "${scopedName user name} -> ${dep}") (lib.filter (dep: !(u.units ? ${dep})) unit.requires)
        ) u.units
      )
    ) cfg.users
  );
in
{
  options.providers.services = {
    user.backend = lib.mkOption {
      type = lib.types.str;
      default = cfg.backend;
      defaultText = lib.literalExpression "config.providers.services.backend";
      description = ''
        The implementation supervising per-user units.

        When it is the same as {option}`providers.services.backend`, which is the default,
        there is no second supervisor: a user's units are emitted into the system one, owned by
        that user. They are then ordinary units, so they may require system units freely.

        When it differs, the system supervisor runs the user one as a unit of its own, and a
        user's units are that supervisor's business. The two cannot observe each other, so a
        user unit may then only depend on other units of the same user - what the whole tree
        depends on is whatever the unit running its supervisor depends on.
      '';
    };

    user.supported = lib.mkOption {
      type = lib.types.bool;
      internal = true;
      default = false;
      description = ''
        Set by whichever implementation is able to act as the per-user supervisor named by
        {option}`providers.services.user.backend`. An implementation with no per-user mode
        simply never sets it, and naming it there is then refused.
      '';
    };

    users = lib.mkOption {
      default = { };
      description = ''
        Per-user service graphs, one per user.

        A user's units are written as if that user were the only thing on the machine, and are
        named for the system as a whole when emitted - `pipewire` belonging to `alice` becomes
        `pipewire@alice`. Edges naming another of that user's units are scoped with them;
        anything else refers to a system unit.

        These are ordinary units in every other respect, and in particular they start at boot
        rather than at login. A service which must follow a login session needs something to
        gate it on that session, which is not something this describes.
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.units = lib.mkOption {
            inherit (options.providers.services.units) type;
            default = { };
            description = ''
              This user's units. See {option}`providers.services.units`.
            '';
          };
        }
      );
    };
  };

  config = {
    # only under the first rule. when a separate user supervisor is named it owns these, and
    # emitting them into the system supervisor as well would run every one of them twice.
    providers.services.units = lib.mkIf (cfg.user.backend == cfg.backend) flattened;

    assertions = [
      {
        assertion = (cfg.user.backend != cfg.backend) -> cfg.user.supported;
        message = ''
          providers.services.user.backend is ${cfg.user.backend}, which has no per-user mode -
          it can supervise a system, but cannot be run as one user's own service manager.

          finit is the case this usually means: it can run a unit as a given user, which is
          what the first rule uses, but it has no per-user instance. Either leave
          user.backend as ${cfg.backend} so that user units are owned by the system supervisor,
          or name an implementation which can serve the user scope.
        '';
      }

      {
        assertion = (cfg.user.backend != cfg.backend) -> crossScope == [ ];
        message = ''
          providers.services.user.backend is ${cfg.user.backend} rather than ${cfg.backend}, so
          per-user units are supervised separately from system units and the two cannot observe
          each other. These edges leave a user's own tree and so cannot be honoured:
          ${lib.concatStringsSep "\n" crossScope}

          Depend on another unit of the same user, or express what the whole tree needs through
          the unit which runs that user's supervisor.
        '';
      }
    ]
    ++ lib.concatLists (
      lib.mapAttrsToList (
        user: u:
        lib.mapAttrsToList (name: _: {
          assertion = !(cfg.units ? ${name}) || flattened ? ${name};
          message = ''
            providers.services.users.${user}.units.${name} is emitted as ${scopedName user name},
            which collides with a system unit of that name.
          '';
        }) u.units
      ) cfg.users
    );
  };
}
