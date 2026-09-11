# a providers.services implementation backed by s6-rc
#
# s6-rc is unlike the others in three ways, and each one exercises something the contract has
# not had to express before.
#
# its configuration is compiled, not read. a source tree is fed to `s6-rc-compile`, which
# produces a binary database, and the supervisor runs against that - so the artifact this
# backend produces is a built database in the store rather than files an init parses at boot.
#
# it speaks s6 readiness natively, through `notification-fd`, which finit only manages because
# finit happens to speak the protocol and dinit refuses outright. it has no notion of a pid
# file at all, so this is the first implementation whose readiness set is neither a prefix nor
# a superset of another's.
#
# and it has native down scripts, so shutdown work is an ordinary property of a unit rather
# than something to be reconstructed - finit needed a generated script and dinit needed an
# inverted chain of stop-commands.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};
  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);
  commandOf = unit: (variantOf unit).command or null;

  s6rc = pkgs.s6-rc;

  # s6-rc dependencies order the change operations and nothing else: a longrun which dies is
  # restarted by its supervisor, and nothing depending on it is touched. that is the contract's
  # start-only edge without any emulation, which only dinit has otherwise managed.
  dependencies = unit: lib.concatMapStrings (dep: "${dep}\n") unit.requires;

  runScript =
    name: unit:
    pkgs.writeShellScript "${name}-run" ''
      ${lib.optionalString (unit.path != [ ]) "export PATH=${lib.makeBinPath unit.path}:$PATH"}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}") unit.environment
      )}
      exec ${
        lib.optionalString (unit.user != null) "${lib.getExe' pkgs.s6 "s6-setuidgid"} ${unit.user} "
      }${commandOf unit}
    '';

  # one directory per unit, in the source layout s6-rc-compile expects
  unitDir =
    name: unit:
    let
      kind = kindOf unit;
    in
    ''
      mkdir -p $out/source/${name}
      printf '%s\n' ${if kind == "service" then "longrun" else "oneshot"} > $out/source/${name}/type
      printf '%s' ${lib.escapeShellArg (dependencies unit)} > $out/source/${name}/dependencies
    ''
    + (
      # a longrun's `run` is an executable the supervisor execs, but a oneshot's `up` is an
      # execline command line which s6-rc-compile reads as text - so one is linked in and the
      # other is written out. linking a binary in as `up` makes s6-rc try to parse an ELF
      # header as a command.
      if kind == "service" then
        ''
          ln -s ${runScript name unit} $out/source/${name}/run
        ''
        # readiness by `fork` means no notification at all: s6 calls it up once spawned
        + lib.optionalString (readinessOf unit == "s6") ''
          printf '3\n' > $out/source/${name}/notification-fd
        ''
      else if kind == "oneshot" then
        ''
          printf '%s\n' ${runScript name unit} > $out/source/${name}/up
        ''
      else
        # an anchor has no process, and s6-rc has no process-less kind - but a oneshot whose
        # `up` does nothing is exactly that, and costs one `true` at the moment it comes up
        ''
          printf '%s\n' ${lib.getExe' pkgs.coreutils "true"} > $out/source/${name}/up
        ''
    )
    + lib.optionalString (unit.startTimeout != null) ''
      printf '%d\n' ${toString (unit.startTimeout * 1000)} > $out/source/${name}/timeout-up
    ''
    + lib.optionalString (unit.stopTimeout != null) ''
      printf '%d\n' ${toString (unit.stopTimeout * 1000)} > $out/source/${name}/timeout-down
    '';

  # the whole point of this backend: the database is built here, not assembled at boot. a
  # configuration error is a build failure rather than something discovered on the machine.
  database = pkgs.runCommand "s6-rc-database" { nativeBuildInputs = [ s6rc ]; } ''
    mkdir -p $out
    ${lib.concatStrings (lib.mapAttrsToList unitDir enabled)}

    mkdir -p $out/source/everything
    printf 'bundle\n' > $out/source/everything/type
    printf '%s' ${
      lib.escapeShellArg (lib.concatMapStrings (n: "${n}\n") (lib.attrNames enabled))
    } > $out/source/everything/contents

    s6-rc-compile $out/db $out/source
  '';

  live = "/run/s6-rc";
  scanDir = "/run/service";
in
{
  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "s6-rc" ];
    };

    s6-rc.database = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = ''
        The compiled service database.

        s6-rc runs against a database rather than a directory of configuration, so this is
        built rather than written out - a malformed unit fails the build instead of the boot.

        Hosting is the system's business, as s6-rc supervises under whatever is PID 1:
        `s6-svscan` over a scan directory, then `s6-rc-init -c <this>/db -l ${live}` against it.
        See `tests/providers/services-s6rc.nix`.
      '';
    };
  };

  config = lib.mkIf (cfg.backend == "s6-rc") {
    providers.services.s6-rc.database = database;

    providers.services.supportedFeatures = {
      # `timeout-up` and `timeout-down`, per unit
      startTimeout = true;
      stopTimeout = true;

      # no process-less kind, so an anchor is a oneshot running `true`
      nativeAnchors = false;

      # dependencies order change operations; a longrun which dies takes nothing with it
      nativeStartOnlyEdges = true;

      # native s6 notification, and no notion of a pid file at all
      readiness = [
        "fork"
        "s6"
      ];

      user = true;
      group = false;
      path = true;
    };

    providers.services.switch = {
      list = pkgs.writeShellScript "s6-rc-list" ''
        ${lib.getExe' s6rc "s6-rc"} -l ${live} -a list 2>/dev/null | while read -r unit; do
          fp="/etc/s6-rc-fingerprints/$unit"
          [ -e "$fp" ] && printf '%s\t%s\n' "$unit" "$(cat "$fp")"
        done
      '';

      # `change` is bulk and atomic, which is what the engine hands it anyway
      activate = pkgs.writeShellScript "s6-rc-activate" ''
        ${lib.getExe' s6rc "s6-rc"} -l ${live} -u change $(cat)
      '';

      deactivate = pkgs.writeShellScript "s6-rc-deactivate" ''
        ${lib.getExe' s6rc "s6-rc"} -l ${live} -d change $(cat)
      '';
    };

    # how to be run, for whatever is PID 1. it never learns what any of this means.
    providers.services.hosting = {
      prepare = pkgs.writeShellScript "s6-rc-prepare" ''
        ${lib.getExe' pkgs.coreutils "mkdir"} -p ${scanDir}
      '';

      command = "${lib.getExe' pkgs.s6 "s6-svscan"} ${scanDir}";

      # the database is compiled, so bringing it up is a step of its own rather than a
      # directory the supervisor notices
      activate = pkgs.writeShellScript "s6-rc-activate-all" ''
        ${lib.getExe' s6rc "s6-rc-init"} -c ${database}/db -l ${live} ${scanDir}
        ${lib.getExe' s6rc "s6-rc"} -l ${live} -u change everything
      '';
    };

    environment.etc = lib.mapAttrs' (
      name: fp: lib.nameValuePair "s6-rc-fingerprints/${name}" { text = fp; }
    ) cfg.switch.fingerprints;
  };
}
