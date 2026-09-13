# how kernel variables are applied, as a providers.services unit
#
# Separated from the module's own options and configuration so that what it asks of the
# contract is in one place, the same way a module implementing a `providers.*` contract keeps
# its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  # generated here, beside the unit which names it and the /etc entry which publishes it. The
  # unit cannot reach it through `environment.etc` - that is where implementations put the unit
  # itself, so it would be a definition in terms of itself.
  sysctlConf = pkgs.writeText "60-finix.conf" (
    lib.concatStrings (
      lib.mapAttrsToList (
        n: v: lib.optionalString (v != null) "${n}=${if v == false then "0" else toString v}\n"
      ) config.boot.kernel.sysctl
    )
  );
in
{
  config = {
    environment.etc."sysctl.d/60-finix.conf".source = sysctlConf;

    providers.services.units.sysctl = {
      description = "apply kernel variables";

      # the head of the trunk: anything started after this should see the values it sets
      requires = [ (lib.head config.providers.services.trunk.levels) ];

      # the generated file directly, not `config.environment.etc.<...>.source`. Most
      # implementations lower a unit into /etc, so a unit whose command reads back out of
      # `environment.etc` is defined in terms of itself - which surfaces as infinite recursion
      # rather than as anything a person could read.
      #
      # `-e` because a key the running kernel does not have is not a reason to stop booting.
      # As a finit task this was free - nothing waited on a task - but a unit at the head of
      # the trunk is waited for by every level above it, so one stale entry in
      # boot.kernel.sysctl would otherwise take the whole machine down with it.
      type.oneshot.command = "${pkgs.procps}/bin/sysctl -e -p ${sysctlConf}";
    };
  };
}
