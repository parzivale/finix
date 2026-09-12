# the shutdown side of the trunk, as one script
#
# A normal trunk level means "everything before me has started". The latch cannot mean that: it
# means "everything before me has *stopped*", which is not a fact about starting and so has no
# edge to hang on. Units attached to it or to a level after it therefore run on the way down.
#
# That asks two things of an implementation - that such a unit runs only during shutdown, and
# that the units run in trunk order - and no init reliably offers the second:
#
#   finit  `run` stanzas are ordered against other commands, not against the power-off, so the
#          sequence could be outrun entirely and the machine go down before it executed.
#   dinit  the inverted depends-on chain is correct on paper and not honoured during a full
#          shutdown; the later step ran first.
#   runit  no dependency mechanism and no runlevels at all.
#   s6-rc  the bundle comes up at boot, so the timing is wrong even where the order is right.
#
# So ordering is not asked of the init. The whole shutdown side is lowered here into a single
# script, in trunk order, and each implementation hands that one script to the single point it
# does reach reliably on the way down - `HOOK_SHUTDOWN` on finit, the latch's `stop-command` on
# dinit, stage 3 on runit, `rc.shutdown` on s6. Ordering becomes the shell's job, which is a
# guarantee that does hold.
#
# The other half is the implementation's own: a unit on this side must be kept out of whatever
# starts at boot.
{ pkgs, lib }:
rec {
  indexOf =
    trunk: name:
    lib.findFirst (i: i != null) null (lib.imap0 (i: l: if l == name then i else null) trunk.levels);

  # which trunk level a unit belongs to: itself if it is one, otherwise the one it attached to.
  # attaching to more than one is refused by the contract, so the first match is the only match.
  levelFor =
    trunk: name: unit:
    if lib.elem name trunk.levels then
      name
    else
      lib.findFirst (dep: lib.elem dep trunk.levels) null unit.requires;

  onShutdownSide =
    trunk: name: unit:
    let
      latchIndex = indexOf trunk trunk.latch;
      level = levelFor trunk name unit;
    in
    latchIndex != null && level != null && indexOf trunk level >= latchIndex;

  # where a unit sits in the trunk, as a number. This orders the steps of the script below; no
  # init ever sees it. A level sorts before the units attached to it, so a unit attached to a
  # later level runs after everything attached to an earlier one.
  priorityFor =
    trunk: name: unit:
    let
      i = indexOf trunk (levelFor trunk name unit);
    in
    if lib.elem name trunk.levels then i * 100 else i * 100 + 50;

  # the shutdown-side units of a configuration, in the order they must run
  orderedFor =
    cfg:
    let
      enabled = lib.filterAttrs (_: u: u.enable) cfg.units;
    in
    lib.sort (a: b: a.priority < b.priority) (
      lib.mapAttrsToList (
        name: unit:
        unit
        // {
          inherit name;
          priority = priorityFor cfg.trunk name unit;
        }
      ) (lib.filterAttrs (onShutdownSide cfg.trunk) enabled)
    );

  # `setpriv` rather than `su`: it becomes the user and their groups and execs, with no PAM
  # session, no login shell and no password database lookup beyond resolving the name. A
  # machine on its way down is the worst place to discover that PAM needs something which has
  # already been stopped.
  #
  # Without this the whole script would run as root, and a step belonging to a unit which asked
  # to run as somebody else would run with more privilege than it asked for - the same failure
  # the contract warns about for `supportedFeatures.user`, arrived at by the back door.
  asUser =
    unit:
    if unit.user == null then
      ""
    else
      "${lib.getExe' pkgs.util-linux "setpriv"} --reuid ${unit.user}"
      + lib.optionalString (unit.group != null) " --regid ${unit.group}"
      + " --init-groups -- ";

  # null when a configuration has no shutdown-side unit with anything to run
  scriptFor =
    cfg:
    let
      commandOf =
        unit:
        let
          kind = lib.head (lib.attrNames unit.type);
        in
        unit.type.${kind}.command or null;

      steps = lib.filter (u: commandOf u != null) (orderedFor cfg);
    in
    if steps == [ ] then
      null
    else
      pkgs.writeShellScript "providers-services-shutdown" (
        lib.concatMapStringsSep "\n" (unit: ''
          echo "shutdown: ${unit.name}" > /dev/kmsg 2>/dev/null || true
          ${asUser unit}${commandOf unit}
        '') steps
      );
}
