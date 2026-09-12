{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.resolvconf;

  # what openresolv calls when a subscriber has to pick up new nameservers.
  #
  # `$1` is a daemon's name, and what it needs is to reread resolv.conf - which is precisely
  # what that unit's `reload` says, in the module author's own words. So this dispatches to the
  # reload commands which already exist rather than asking an init to restart the thing:
  # `initctl restart $1`, which is what this was, went through finit and dropped the process to
  # do something the daemon would have done in place.
  #
  # A subscriber with no reload declared is one where rereading is not something it can be
  # asked to do, and that is worth saying out loud rather than papering over with a restart.
  reloadable = lib.filterAttrs (
    _: unit: unit.type ? service && unit.type.service.reload != null
  ) config.providers.services.units;

  restartCmd = pkgs.writeShellScript "resolvconf-reload" ''
    case "$1" in
      ${lib.concatStringsSep "\n  " (
        lib.mapAttrsToList (name: unit: "${name}) exec ${unit.type.service.reload} ;;") reloadable
      )}
      *)
        echo "resolvconf: $1 declares no reload, so it has not been told about the new nameservers" >&2
        exit 1
        ;;
    esac
  '';

  listToValue = lib.concatMapStringsSep " " (lib.generators.mkValueStringDefault { });

  format = (pkgs.formats.keyValue { inherit listToValue; }) // {
    generate =
      name: value:
      let
        transformedValue = lib.mapAttrs (
          key: val:
          if lib.isList val then
            "'" + listToValue val + "'"
          else if lib.isBool val then
            lib.boolToString val
          else
            toString val
        ) value;
      in
      pkgs.writeText name (lib.generators.toKeyValue { } transformedValue);
  };
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "programs" "openresolv" ] [ "programs" "resolvconf" ])
  ];

  options.programs.resolvconf = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to enable [resolvconf](${pkgs.openresolv.meta.homepage}).
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openresolv;
      defaultText = lib.literalExpression "pkgs.openresolv";
      description = ''
        The package to use for `resolvconf`.
      '';
    };

    settings = lib.mkOption {
      type = format.type;
      default = { };
      description = ''
        `resolvconf` configuration. See {manpage}`resolvconf.conf(5)`
        for additional details.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.resolvconf.settings = {
      interface_order = [
        "lo"
        "lo[0-9]"
      ];
      resolv_conf = "/etc/resolv.conf";
      RESTARTCMD = "${restartCmd} $1";
      libc_restart = true; # NOTE: needed until we have nscd service
    };

    environment.etc."resolvconf.conf".source = format.generate "resolvconf.conf" cfg.settings;

    environment.systemPackages = [ cfg.package ];

    providers.services.units.resolvconf = {
      description = "update resolv.conf from the interface records";

      # early, and before anything which resolves a name: the records are written by whatever
      # configured the interface, and this is what turns them into /etc/resolv.conf
      requires = [ "sysinit" ];

      type.oneshot.command = "${lib.getExe cfg.package} -u";
    };
  };
}
