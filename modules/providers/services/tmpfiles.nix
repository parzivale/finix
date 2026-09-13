# volatile file setup, as part of the services contract
#
# tmpfiles belongs here rather than in its own contract because only an init implements it.
# Everything on the machine which needs a directory in /run before it starts says so, and
# something has to put them there exactly once, early, before the things which depend on them.
# That is an init's job and nobody else's.
#
# A rule is an attrset, not a line of tmpfiles.d(5), and it is lowered into commands here at
# build time. That is the whole reason no implementation needs a reader: the text form only
# ever existed to be parsed back into the fields it was rendered from, and finit and systemd
# are the only two inits which ship a parser for it. Keeping the fields means dinit, runit and
# s6 need nothing they do not already have, and nothing in this repo has to grow a tmpfiles.d
# implementation to be selectable as a backend.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  ruleType = lib.types.submodule {
    options = {
      type = lib.mkOption {
        type = lib.types.enum [
          "directory"
          "file"
          "symlink"
          "permissions"
          "remove"
        ];
        description = ''
          What the rule does.

          `directory` and `file` create the path if it is not already there; `symlink` points
          it at {option}`argument`. `permissions` creates nothing and only changes a path
          which already exists, for something another unit or the kernel has made. `remove`
          deletes it, and is the one type whose {option}`path` may be a glob.
        '';
      };

      path = lib.mkOption {
        type = lib.types.str;
        description = ''
          The absolute path the rule applies to.

          Taken literally, not as a pattern - except for a `remove` rule, where shell glob
          characters match and a pattern matching nothing is not an error.
        '';
      };

      recursive = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the rule descends into the path's contents. Meaningful for `permissions`,
          which then applies to everything beneath the path, and for `remove`, which will
          otherwise refuse a non-empty directory.
        '';
      };

      mode = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        example = "0755";
        description = ''
          Access mode, as {manpage}`chmod(1)` would take it. `null` leaves it alone - for a
          path being created, that means the process umask decides.
        '';
      };

      user = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = ''
          Owning user, by name or numeric id. `null` leaves ownership with whoever created
          the path, which this early in boot is root.
        '';
      };

      group = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = "Owning group, by name or numeric id. `null` leaves it alone.";
      };

      argument = lib.mkOption {
        type = with lib.types; nullOr str;
        default = null;
        description = ''
          The target, for a `symlink`, or the initial contents, for a `file`. Meaningless for
          the other types.
        '';
      };
    };
  };

  arg = lib.escapeShellArg;

  # each rule becomes the commands it means, written out now rather than a line for something
  # on the machine to parse later
  lower =
    rule:
    let
      owner = lib.optionalString (rule.user != null) "-o ${arg rule.user}";
      grp = lib.optionalString (rule.group != null) "-g ${arg rule.group}";
      mode = lib.optionalString (rule.mode != null) "-m ${arg rule.mode}";
      path = arg rule.path;
    in
    {
      # `install -d` is mkdir, chmod and chown in one, and is idempotent
      directory = "install -d ${mode} ${owner} ${grp} ${path}";

      # only if absent: a file which already has contents is not ours to truncate
      file = ''
        if [ ! -e ${path} ]; then
          install -D ${mode} ${owner} ${grp} /dev/null ${path}
          ${lib.optionalString (rule.argument != null) "printf '%s' ${arg rule.argument} > ${path}"}
        fi
      '';

      symlink = "ln -sfn ${arg (toString rule.argument)} ${path}";

      # creates nothing, so a path that is not there yet is not an error - something else owns
      # its existence and this rule only has an opinion about its permissions
      permissions =
        let
          r = lib.optionalString rule.recursive "-R ";
        in
        ''
          if [ -e ${path} ]; then
            ${lib.optionalString (rule.mode != null) "chmod ${r}${arg rule.mode} ${path}"}
            ${lib.optionalString (rule.user != null) "chown ${r}${arg rule.user} ${path}"}
            ${lib.optionalString (rule.group != null) "chgrp ${r}${arg rule.group} ${path}"}
          fi
        '';

      # the one type taking a pattern, so the path is deliberately left unquoted for the shell
      # to expand. An unmatched glob stays literal, which the existence check then discards -
      # so a pattern matching nothing does nothing rather than failing the unit.
      remove = ''
        # SC2043: the loop is how a glob is handled, and a path with no glob in it is simply
        # the one-iteration case rather than a mistake
        # shellcheck disable=SC2043
        for candidate in ${rule.path}; do
          if [ -e "$candidate" ]; then
            rm -${lib.optionalString rule.recursive "r"}f -- "$candidate"
          fi
        done
      '';
    }
    .${rule.type};
in
{
  options.providers.services.tmpfiles.rules = lib.mkOption {
    type = lib.types.listOf ruleType;
    default = [ ];

    example = lib.literalExpression ''
      [
        {
          type = "directory";
          path = "/run/postgresql";
          mode = "0755";
          user = "postgres";
          group = "postgres";
        }
      ]
    '';

    description = ''
      Volatile files and directories to put in place during early boot, as the `tmpfiles-setup`
      unit at the head of the trunk - so everything attached to any later trunk level is behind
      them.

      Rules are attrsets rather than {manpage}`tmpfiles.d(5)` lines because they are lowered
      into commands when the system is built. Nothing on the machine parses them, so an
      implementation needs no reader of that format to be selectable as a backend - which
      matters for dinit, runit and s6, none of which ship one.
    '';
  };

  config = {
    # a symlink with nothing to point at is a configuration error, not an empty link. Checked
    # here rather than in the rule submodule: assertions declared inside an option's type are
    # never collected into config.assertions, so one there would never fire.
    assertions = map (rule: {
      assertion = (rule.type == "symlink") -> (rule.argument != null);
      message = "providers.services.tmpfiles rule for ${rule.path} is a symlink with no argument to point at";
    }) cfg.tmpfiles.rules;

    # a contract unit rather than anything the implementation has to wire up: every backend
    # gets this by implementing the contract, and none of them has to know it exists.
    providers.services.units.tmpfiles-setup = {
      description = "create volatile files and directories";

      # every rule is attempted, and one which fails is reported rather than fatal.
      #
      # This was a `writeShellApplication`, which prepends `set -euo pipefail` - so the first
      # rule to fail ended the script, every rule after it never ran, and the unit never
      # completed. Everything in the trunk waits on this one, so a single unhappy rule took the
      # whole machine with it and said nothing about which rule it was: the boot simply stopped
      # after "create volatile files and directories" with no error to go on.
      #
      # A directory which cannot be created is a daemon which will fail to start later, and a
      # daemon failing for a legible reason on a machine that booted beats a machine that did
      # not. The name of the path goes to stderr, which is the console and the log.
      type.oneshot.command = pkgs.writeShellScript "tmpfiles-setup" ''
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

        # a running log, not only a list of failures.
        #
        # Where a unit's output goes is the implementation's business - finit sends it to
        # /dev/null unless the stanza asks for a log - so stderr alone tells nobody anything
        # afterwards. /run is mounted before any unit runs, so this file is readable once the
        # machine is up.
        #
        # Each rule is announced *before* it runs rather than after, which is what makes this
        # useful for a rule which never returns: the last line of the log is then either the
        # rule which failed or the rule still running, and those are the only two ways this
        # unit can fail to complete.
        log=/run/tmpfiles-setup.log
        : > "$log"

        failed=0

        ${lib.concatMapStringsSep "\n" (rule: ''
          echo "${rule.type} ${rule.path}" >> "$log"
          if ! (
            ${lower rule}
          ); then
            echo "  FAILED: ${rule.type} rule for ${rule.path}" | tee -a "$log" >&2
            failed=$((failed + 1))
          fi
        '') cfg.tmpfiles.rules}

        echo "done: ${toString (lib.length cfg.tmpfiles.rules)} rules, $failed failed" >> "$log"

        if [ "$failed" -gt 0 ]; then
          echo "tmpfiles-setup: $failed of ${toString (lib.length cfg.tmpfiles.rules)} rules failed, see $log" >&2
        fi
      '';

      # the earliest point in the trunk, so that every *later level* - and so everything
      # attached to any of them - is behind the files it puts in place.
      #
      # Its own tier is not, and that is the part worth being careful about: units attached to
      # one level start together, so anything in the head tier which wants a directory from
      # here has to name this unit, exactly as this one names the mount below. dbus is the
      # case which found it - it binds a socket in /run/dbus and died on every boot until the
      # directory happened to exist, which finit papered over by restarting it until it did.
      #
      # After the mounts, for the same class of reason: a rule writing into /var before /var is
      # mounted puts the files on the root filesystem, where the real /var is then mounted on
      # top of them and they are neither present nor recoverable.
      requires = [
        (lib.head cfg.trunk.levels)
        "mount-filesystems"
      ];
    };
  };
}
