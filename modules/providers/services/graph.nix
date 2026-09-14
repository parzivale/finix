# the unit graph, as a picture
#
# A configuration's units are a graph, and the questions people actually have about one are
# shaped like a graph: what starts before what, what is in the same tier as what, what is
# waiting on the thing that hangs. Reading that out of `providers.services.units` means holding
# two hundred `requires` lists in your head at once, which nobody does - so this renders it.
#
# Mermaid because it needs no tooling to look at: a `.mmd` file pastes into anything which
# renders markdown, and the graph is text, so two generations of it diff.
#
# What is drawn is the *contract's* graph, not the backend's. An implementation adds units of
# its own - finit's companion latches, dinit's `-ready` services, runit's synthesised edges -
# and those are the translation rather than the configuration, so they are deliberately absent:
# the point of the picture is what this machine asked for, which is the same on every backend.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  isLevel = name: lib.elem name trunk.levels;

  # which level a unit sits on: itself if it is one, otherwise the level it attached to. A unit
  # may name only one, so the first match is the only match - and `null` means it named none,
  # which is the interesting case below.
  levelOf = name: unit: if isLevel name then name else lib.findFirst isLevel null unit.requires;

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};

  # the readiness a unit ended up with, as the tag which names it. By the time this runs the
  # contract has already resolved the preference list against the backend, so what is drawn is
  # the one that was chosen rather than the ones that were offered.
  tagOf =
    r:
    let
      k = if lib.isString r then r else lib.head (lib.attrNames r);
    in
    if k == "waitFor" && !(lib.isString r) then "waitFor.${lib.head (lib.attrNames r.waitFor)}" else k;

  readinessOf =
    unit:
    let
      v = variantOf unit;
    in
    if !(v ? readiness) then
      null
    else if lib.isList v.readiness then
      (if v.readiness == [ ] then null else tagOf (lib.head v.readiness))
    else
      tagOf v.readiness;

  # mermaid ids are bare words, and a unit name is not: `network-online` would be read as a
  # subtraction. The prefix keeps a unit called `end` or `graph` from colliding with the
  # language's own keywords.
  idOf =
    prefix: name:
    prefix + lib.stringAsChars (c: if builtins.match "[A-Za-z0-9_]" c != null then c else "_") name;

  unitId = idOf "u_";

  # shape carries the kind, so the picture says what a node is without a legend: a hexagon is a
  # trunk level, a rounded box a long-running service, a square box something which runs once.
  nodeFor =
    name: unit:
    let
      readiness = readinessOf unit;

      # what kind of unit it is, spelled out on a second line rather than left to the shape.
      # A trunk level is called `level` rather than `anchor`, which is what it is made of: an
      # ordinary anchor a module declared is a different thing to read past, and the two are
      # worth telling apart at a glance.
      kind = if isLevel name then "level" else kindOf unit;

      # and what else is worth knowing about that kind. For a service it is the readiness it
      # resolved to, which is the part of a unit most likely to be wrong and least likely to
      # be visible. For the latch it is the word `latch`: it is the one level with no incoming
      # edge, so the graph falls into two pieces there, and unlabelled that reads like a
      # missing edge rather than the shutdown side beginning.
      note =
        if isLevel name && name == trunk.latch then
          " · latch"
        else if readiness != null then
          " · ${readiness}"
        else
          "";

      label = ''"${name}<br/>${kind}${note}"'';
      id = unitId name;

      class = if isFloating name unit then "floating" else kindOf unit;
    in
    if isLevel name then
      "${id}{{${label}}}:::level"
    else if kindOf unit == "service" then
      "${id}(${label}):::${class}"
    else if kindOf unit == "oneshot" then
      "${id}[${label}]:::${class}"
    else
      "${id}([${label}]):::${class}";

  # every edge the configuration declared, drawn as declared. A level's own `requires` holds
  # each unit attached to it, so the fan-in to a level is the tier, and the fan-out of a level
  # is the tier after it - there is nothing to collapse or group, and grouping it was the thing
  # which made the first version of this unreadable.
  edgesOf =
    name: unit:
    map (dep: "  ${unitId dep} --> ${unitId name}") (lib.filter (dep: enabled ? ${dep}) unit.requires);

  # a unit which named no level. Nothing about where it is drawn changes - it hangs off
  # whatever it requires, like everything else - but it gets its own colour, because "no level
  # waits for this" is a fact about the graph rather than a decoration.
  isFloating = name: unit: !(isLevel name) && levelOf name unit == null;

  mermaid = lib.concatStringsSep "\n" (
    [
      "---"
      "title: ${
        config.networking.hostName or "finix"
      } · ${cfg.backend} · ${toString (lib.length (lib.attrNames enabled))} units"
      "---"

      # left to right, because that is the direction the boot runs in and a tier is then a
      # column of units rather than a row which grows off the side of the page
      "flowchart LR"
      "  %% hexagon: trunk level. rounded: service. square: oneshot. stadium: anchor."
      "  %% red: attached to no level, so no level waits for it."
      "  classDef level fill:#111827,stroke:#6b7280,color:#f9fafb,stroke-width:2px"
      "  classDef service fill:#0b3b57,stroke:#3b9fd9,color:#e6f4ff"
      "  classDef oneshot fill:#2e2712,stroke:#a98520,color:#fdf3d8"
      "  classDef anchor fill:#1b2f22,stroke:#4f9e6a,color:#e8f7ee"
      "  classDef floating fill:#3b1219,stroke:#d2596e,color:#ffe4e9"
      ""
    ]

    # the nodes first and the edges after, so that a node is declared once with its shape and
    # class rather than picking them up from whichever edge happened to mention it first
    ++ lib.mapAttrsToList (name: unit: "  ${nodeFor name unit}") enabled
    ++ [ "" ]
    ++ lib.concatLists (lib.mapAttrsToList edgesOf enabled)
    ++ [ "" ]
  );
in
{
  config = {
    # a file rather than an option holding a string: it is something to look at, and
    # `nix-build -A config.system.build.serviceGraph` then `cat` is the whole workflow.
    system.build.serviceGraph = pkgs.writeText "service-graph-${config.networking.hostName or "finix"}.mmd" mermaid;
  };
}
