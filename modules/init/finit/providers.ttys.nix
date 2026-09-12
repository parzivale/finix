# providers.ttys, on finit, is finit's own tty stanzas
#
# finit is the one implementation with a first-class terminal: it opens the device, prints the
# `Press Enter to activate console` prompt unless told not to, runs a login prompt of its own
# when none is named, and respawns it when the session ends. So the provider hands it the
# devices directly rather than lowering them to services, which would reimplement all of that
# badly and lose the built-in getty entirely.
{
  config,
  lib,
  ...
}:
let
  cfg = config.providers.ttys;

  # a tty stanza is not a contract unit, so the trunk does not order it - finit starts it when
  # the runlevel is entered, which says nothing about which units are up. What it does take is
  # conditions, and every contract unit has a companion task which latches once that unit has
  # started, so `requires` is expressible exactly.
  #
  # This is the companion name from providers.services.nix. Repeated rather than shared because
  # the two files are the same implementation, and a condition string is the whole of what
  # passes between them.
  conditionOf = name: "task/${name}-started/success";

  enabled = lib.filterAttrs (_: device: device.enable) cfg.devices;
in
{
  config = lib.mkIf (config.providers.services.backend == "finit") {
    providers.ttys.native = true;

    finit.ttys = lib.mapAttrs (
      name: device:
      {
        inherit (device) description;

        # no "press Enter to activate console" - a prompt which has to be woken up is not a
        # prompt, and it is not what any other implementation would do with the same device
        nowait = true;

        conditions = map conditionOf device.requires;
      }
      # a command and a device are alternatives in finit's syntax: naming a command means the
      # program opens the device itself, and leaving it out means finit runs its own getty on
      # the device it is named after. Which is why `command` stays null here when the provider
      # was not given one - it is the case finit is better at than the fallback.
      // lib.optionalAttrs (device.command != null) { inherit (device) command; }
      // lib.optionalAttrs (device.command == null && cfg.package != null) {
        command = "${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs} ${name}";
      }
    ) enabled;
  };
}
