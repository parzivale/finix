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

  # shared by whichever variants below actually take them, rather than sitting on every rule
  # regardless of kind - a `directory` rule setting `recursive`, or a `file` rule setting
  # `argument` meaning something the type system never asked it to, used to be representable
  # and silently ignored by `lower`. Declared once so `directory`'s `mode`/`user`/`group` and
  # `permissions`'s are the same option, not two definitions which could drift apart.
  mode = lib.mkOption {
    type = with lib.types; nullOr str;
    default = null;
    example = "0755";
    description = ''
      Access mode, as {manpage}`chmod(1)` would take it. `null` leaves it alone - for a path
      being created, that means the process umask decides.
    '';
  };

  user = lib.mkOption {
    type = with lib.types; nullOr str;
    default = null;
    description = ''
      Owning user, by name or numeric id. `null` leaves ownership with whoever created the
      path, which this early in boot is root.
    '';
  };

  group = lib.mkOption {
    type = with lib.types; nullOr str;
    default = null;
    description = "Owning group, by name or numeric id. `null` leaves it alone.";
  };

  recursive = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Whether the rule descends into the path's contents. `permissions` then applies to
      everything beneath the path; `remove` otherwise refuses a non-empty directory.
    '';
  };

  ruleType = lib.types.submodule {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        description = ''
          The absolute path the rule applies to.

          Taken literally, not as a pattern - except for a `remove` rule, where shell glob
          characters match and a pattern matching nothing is not an error.
        '';
      };

      type = lib.mkOption {
        description = ''
          What the rule does, and whatever that needs.

          `directory` and `file` create the path if it is not already there. `symlink` points
          it at {option}`argument`, which that kind alone requires. `permissions` creates
          nothing and only changes a path which already exists, for something another unit or
          the kernel has made. `remove` deletes it, and is the one kind whose {option}`path`
          may be a glob.

          A kind carrying nothing beyond `path` may be written as a bare string, so
          `type = "remove"` and `type.remove = { }` mean the same thing.
        '';
        type = lib.types.coercedTo lib.types.str (kind: { ${kind} = { }; }) (
          lib.types.attrTag {
            directory = lib.mkOption {
              description = "Create the path as a directory if it is not there yet.";
              type = lib.types.submodule { options = { inherit mode user group; }; };
            };

            file = lib.mkOption {
              description = "Create the path as a file if it is not there yet.";
              type = lib.types.submodule {
                options = {
                  inherit mode user group;
                  argument = lib.mkOption {
                    type = with lib.types; nullOr str;
                    default = null;
                    description = ''
                      Initial contents. `null` creates an empty file.
                    '';
                  };
                };
              };
            };

            symlink = lib.mkOption {
              description = "Point the path at {option}`argument` as a symlink.";
              type = lib.types.submodule {
                options.argument = lib.mkOption {
                  type = lib.types.str;
                  description = "The link's target.";
                };
              };
            };

            permissions = lib.mkOption {
              description = ''
                Change ownership and/or mode on a path which already exists; creates nothing.
              '';
              type = lib.types.submodule { options = { inherit mode user group recursive; }; };
            };

            remove = lib.mkOption {
              description = "Delete the path.";
              type = lib.types.submodule { options = { inherit recursive; }; };
            };
          }
        );
      };
    };
  };

  kindOf = rule: lib.head (lib.attrNames rule.type);
  variantOf = rule: rule.type.${kindOf rule};

  arg = lib.escapeShellArg;

  # each rule becomes the commands it means, written out now rather than a line for something
  # on the machine to parse later
  lower =
    rule:
    let
      v = variantOf rule;
      owner = lib.optionalString (v.user or null != null) "-o ${arg v.user}";
      grp = lib.optionalString (v.group or null != null) "-g ${arg v.group}";
      mode = lib.optionalString (v.mode or null != null) "-m ${arg v.mode}";
      path = arg rule.path;
    in
    {
      # `install -d` is mkdir, chmod and chown in one, and is idempotent
      directory = "install -d ${mode} ${owner} ${grp} ${path}";

      # only if absent: a file which already has contents is not ours to truncate
      file = ''
        if [ ! -e ${path} ]; then
          install -D ${mode} ${owner} ${grp} /dev/null ${path}
          ${lib.optionalString (v.argument != null) "printf '%s' ${arg v.argument} > ${path}"}
        fi
      '';

      # `ln -sfn` onto a path which is a real directory does not replace it - it creates the
      # link *inside* it, silently and successfully. /etc/machine-id then becomes
      # /etc/machine-id/machine-id, and everything which reads a machine id gets the wrong
      # answer with nothing anywhere reporting a problem.
      #
      # So that case is refused outright. It is not something this rule may repair on its own:
      # removing a directory it did not create could take a machine's state with it, and a
      # directory standing where a symlink belongs is a question for whoever put it there.
      #
      # A *symlink* to a directory is not this case, and is replaced as usual - that is the
      # ordinary "the target moved" update, which is what `-f` is for.
      symlink = ''
        if [ -d ${path} ] && [ ! -L ${path} ]; then
          echo "${rule.path} is a directory where a symlink belongs; refusing to link inside it" >&2
          exit 1
        fi

        ln -sfn ${arg v.argument} ${path}
      '';

      # creates nothing, so a path that is not there yet is not an error - something else owns
      # its existence and this rule only has an opinion about its permissions
      permissions =
        let
          r = lib.optionalString v.recursive "-R ";
        in
        ''
          if [ -e ${path} ]; then
            ${lib.optionalString (v.mode != null) "chmod ${r}${arg v.mode} ${path}"}
            ${lib.optionalString (v.user != null) "chown ${r}${arg v.user} ${path}"}
            ${lib.optionalString (v.group != null) "chgrp ${r}${arg v.group} ${path}"}
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
            rm -${lib.optionalString v.recursive "r"}f -- "$candidate"
          fi
        done
      '';
    }
    .${kindOf rule};
in
{
  options.providers.services.tmpfiles.rules = lib.mkOption {
    type = lib.types.listOf ruleType;
    default = [ ];

    example = lib.literalExpression ''
      [
        {
          path = "/run/postgresql";
          type.directory = {
            mode = "0755";
            user = "postgres";
            group = "postgres";
          };
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
          echo "${kindOf rule} ${rule.path}" >> "$log"
          if ! (
            ${lower rule}
          ); then
            # what is actually there, because that is the answer nearly every time: a path
            # left by an older install as the wrong kind of thing. A `directory` rule fails
            # against a regular file and against a dangling symlink, and the failure on its
            # own does not say which.
            found=$(stat -Lc %F ${arg rule.path} 2>/dev/null ||
                    stat -c "broken %F" ${arg rule.path} 2>/dev/null ||
                    echo "nothing")
            echo "  FAILED: ${kindOf rule} rule for ${rule.path} (found: $found)" | tee -a "$log" >&2
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
