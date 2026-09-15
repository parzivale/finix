# how services.dhcpcd runs, as providers.services units
#
# Separated from the module's own options and configuration so that what this module asks of
# the service contract is in one place, the same way a module implementing a `providers.*`
# contract keeps its implementation in a file named for it.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.dhcpcd;

  # dhcpcd shells out to its hook scripts - dhcpcd-run-hooks and libexec/dhcpcd-hooks/* - and
  # those are upstream's, calling bare `mkdir`/`cat`/`rm`/`chmod` rather than absolute paths.
  # So anything which can end up running them needs this, and that is both of the commands
  # below: `dhcpcd -w` runs hooks the same as the supervised one does.
  hookPath = lib.makeBinPath (
    [ pkgs.coreutils ]
    ++ lib.optional config.programs.resolvconf.enable config.programs.resolvconf.package
  );
in
{
  config = lib.mkIf cfg.enable {
    providers.services.units.dhcpcd = {
      description = "dhcp client";

      type.service = {
        # PATH set in the command rather than asked for as a unit property: dinit has no
        # per-unit PATH, and dhcpcd needs it - not for itself, but for the hook scripts it
        # shells out to (dhcpcd-run-hooks and libexec/dhcpcd-hooks/*), which are themselves
        # plain shell scripts calling bare `mkdir`/`cat`/`rm`/`chmod` rather than absolute
        # paths, same as every other unit-provided PATH gets built - unlike this repo's own
        # generated scripts, these are upstream's and outside its control. coreutils covers
        # those unconditionally; resolvconf is added on top only when there's a resolvconf
        # hook that will actually run.
        command = pkgs.writeShellScript "dhcpcd" ''
          export PATH=${hookPath}
          exec ${lib.getExe cfg.package} ${lib.escapeShellArgs cfg.extraArgs}
        '';

        # dhcpcd is not asked whether it is `notify`/`s6`-aware because it isn't - neither
        # protocol is something it speaks. `-w` on the supervised command itself blocks it from
        # doing anything past bringing an interface up until an address exists, which is real
        # and worth having independent of what this reports, but it is not what this reports:
        # `fork` readiness here touches the moment the unit is exec'd, before the command has
        # done anything at all, whatever flags it was given.
        #
        # A second, short-lived invocation of the same flag is what actually observes it:
        # `dhcpcd -w` run again while the supervised one is already up talks to that running
        # manager instead of starting a competing one - the same mechanism `-n`/`-N`/`-x`
        # document as "signal an existing process" - and blocks until it returns the answer
        # rather than polling for one. `timeout` is a backstop, not the real bound: dhcpcd's
        # own reboot/discover/IPv4LL fallbacks already resolve this one way or another well
        # inside it - it exists so a stuck manager cannot hang whatever requires this outright.
        #
        # It carries the same PATH as the command, and for the same reason: this one also
        # runs the hooks. What happens without it is a lease which arrives and is never
        # written down - the hooks fail on `mkdir: command not found` and dhcpcd carries on
        # regardless - and it went unseen because finit sets a PATH of its own which happens
        # to hold coreutils, so the one backend which did not need this was the one it was
        # written on. runit and sinit hand a unit nothing.
        readiness.waitFor.check.command = pkgs.writeShellScript "dhcpcd-ready" ''
          export PATH=${hookPath}

          # nothing is asked until there is something to ask. `dhcpcd -w` talks to a running
          # manager, and if there is no manager it *becomes* one - so a probe which runs
          # before the supervised command has got there starts a second dhcpcd, which then
          # backgrounds itself out of the supervisor's sight. What follows is the unit
          # restarting forever: every start finds that manager already in place, sends it a
          # control command and exits, which the supervisor reads as the service dying.
          #
          # The socket is the manager's own, created once it is up, so waiting for it is
          # waiting for the thing this is supposed to be querying.
          while [ ! -S /run/dhcpcd/sock ]; do
            ${lib.getExe' pkgs.coreutils "sleep"} 0.1
          done

          exec ${lib.getExe' pkgs.coreutils "timeout"} 60 ${lib.getExe cfg.package} -w
        '';
      };

      # `multi-user` itself, not `basic`: attaching to a level makes you a dependant of it,
      # and a level's dependants are what the *next* level waits on - so requiring `basic`
      # was making dhcpcd a prerequisite of `multi-user`, serializing a DHCP lease ahead of
      # getty and everything else that only needs `multi-user`, for no reason any of them
      # actually needs. Nothing before `multi-user` touches the network, and nothing after
      # this point is entitled to assume a lease exists either - `network-online` is the unit
      # that promises that, to whatever actually needs it - so dhcpcd only has to be running
      # by the time the things beside it are, not done.
      requires = [ "multi-user" ];
    };

    providers.services.tmpfiles.rules = [
      {
        path = "/var/db/dhcpcd";
        type.directory.user = "dhcpcd";
      }
      {
        path = "/var/lib/dhcpcd";
        type.directory = {
          user = "dhcpcd";
          group = "dhcpcd";
        };
      }
    ];
  };
}
