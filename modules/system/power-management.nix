# The cpu frequency governor to run at.
#
# Not a sleep concern, and nothing to do with `providers.resumeAndSuspend` - commands to run
# around a suspend belong to that contract, which elogind implements. This is the one part of
# nixos' `powerManagement` namespace which is a property of the machine rather than an event
# on it, and it is here because the option has to live somewhere a module tree can write to:
# `nixos-apple-silicon` sets it, asking for `schedutil` on Apple Silicon.
#
# Imported explicitly, because the governor is a decision rather than a default. Leaving it
# unset is a position: the kernel picks, and on a current kernel that is already `schedutil`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.powerManagement;
in
{
  options.powerManagement.cpuFreqGovernor = lib.mkOption {
    type = with lib.types; nullOr str;
    default = null;
    example = "schedutil";
    description = ''
      The CPU frequency governor to select at startup, written to every cpu which has a
      `scaling_governor` to write.

      `null` leaves whatever the kernel chose.
    '';
  };

  config = lib.mkIf (cfg.cpuFreqGovernor != null) {
    # A oneshot rather than a service: it writes and finishes. sysinit, because the governor is
    # a property of the machine rather than of anything running on it, and the sooner it is set
    # the less of boot runs under the wrong one.
    providers.services.units.cpufreq-governor = {
      description = "select the cpu frequency governor";

      requires = [ "sysinit" ];

      type.oneshot.command = toString (
        pkgs.writeShellScript "cpufreq-governor" ''
          set -eu

          for policy in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -w "$policy" ] || continue
            echo ${lib.escapeShellArg cfg.cpuFreqGovernor} > "$policy"
          done
        ''
      );
    };
  };
}
