{
  config,
  pkgs,
  lib,
  ...
}:
let
  sysctlConf = pkgs.writeText "60-finix.conf" (
    lib.concatStrings (
      lib.mapAttrsToList (
        n: v: lib.optionalString (v != null) "${n}=${if v == false then "0" else toString v}\n"
      ) config.boot.kernel.sysctl
    )
  );

  sysctlOption = lib.mkOptionType {
    name = "sysctl option value";
    check =
      val:
      let
        checkType = x: lib.isBool x || lib.isString x || lib.isInt x || x == null;
      in
      checkType val || (val._type or "" == "override" && checkType val.content);
    merge = loc: defs: lib.mergeOneOption loc (lib.filterOverrides defs);
  };
in
{
  options.boot.kernel.sysctl = lib.mkOption {
    type =
      let
        highestValueType = lib.types.ints.unsigned // {
          merge =
            loc: defs:
            lib.foldl (a: b: if b.value == null then null else lib.max a b.value) 0 (lib.filterOverrides defs);
        };
      in
      lib.types.submodule {
        freeformType = lib.types.attrsOf sysctlOption;
        options = {
          "net.core.rmem_max" = lib.mkOption {
            type = lib.types.nullOr highestValueType;
            default = null;
            description = "The maximum receive socket buffer size in bytes. In case of conflicting values, the highest will be used.";
          };

          "net.core.wmem_max" = lib.mkOption {
            type = lib.types.nullOr highestValueType;
            default = null;
            description = "The maximum send socket buffer size in bytes. In case of conflicting values, the highest will be used.";
          };

          "vm.max_map_count" = lib.mkOption {
            type = lib.types.nullOr highestValueType;
            default = null;
            description = "The maximum number of memory map areas a process may have. In case of conflicting values, the highest will be used.";
          };
        };
      };
    default = { };
    example = lib.literalExpression ''
      { "net.ipv4.tcp_syncookies" = false; "vm.swappiness" = 60; }
    '';
    description = ''
      Runtime parameters of the Linux kernel, as set by
      {manpage}`sysctl(8)`.  Note that sysctl
      parameters names must be enclosed in quotes
      (e.g. `"vm.swappiness"` instead of
      `vm.swappiness`).  The value of each
      parameter may be a string, integer, boolean, or null
      (signifying the option will not appear at all).
    '';
  };

  config = {
    environment.etc."sysctl.d/60-finix.conf".source = sysctlConf;

    # TODO: force reload of all kernel variables -> `command = "${pkgs.procps}/bin/sysctl --load --system";`
    #
    # a contract unit rather than a finit task: kernel variables are not finit's business, and
    # written as a stanza they were applied on finit and nowhere else - a machine booting any
    # other init ran with the kernel's defaults for every one of these.
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

    # Hide kernel pointers (e.g. in /proc/modules) for unprivileged
    # users as these make it easier to exploit kernel vulnerabilities.
    boot.kernel.sysctl."kernel.kptr_restrict" = lib.mkDefault 1;

    # Improve compatibility with applications that allocate
    # a lot of memory, like modern games
    boot.kernel.sysctl."vm.max_map_count" = lib.mkDefault 1048576;
  };
}
