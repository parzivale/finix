# a providers.services implementation backed by sinit
#
# sinit is not an init in the sense every other backend here has one - it is barely a supervisor
# at all. Read in full (92 lines, suckless.org): it blocks every signal, forks and execs exactly
# one compiled-in command as its only child, then loops on `sigwait` answering four signals -
# reap a zombie (SIGCHLD, or a 30 second alarm as a backstop), spawn a poweroff command (SIGUSR1),
# spawn a reboot command (SIGINT, what the kernel sends pid 1 for Ctrl-Alt-Del). If the one child
# it started exits, sinit does nothing at all - no restart, no notice taken. There is no service
# concept, no dependency graph, no readiness notion.
#
# So unlike runit - which has no native *dependency* system but still supervises and respawns
# every service natively via runsv - this backend gets nothing for free. Everything the contract
# promises is built from what sinit actually offers: one long-running child it will never
# restart, and two signals it can be told to answer by running a program.
#
# That "everything" lives in `providers/services/thin.nix` and `pkgs/finix-rc`, shared with
# nxinit, which presents the same surface. What is left here is what is genuinely sinit's: the
# package, the signal numbering, and Ctrl-Alt-Del.
#
# It was two modules of four hundred lines each, generating the same shell twice. The two copies
# are why the shutdown bug - the reboot action destroyed by a `set --` used to test a glob, so
# that every machine asked to reboot powered off - existed in both backends at once.
#
# This is deliberately a minimal implementation: no `notify`/`s6` readiness, no `waitFor.pidfile`
# (same reasoning as runit refusing it - the thing it means, the spawned process forking and
# exiting, would be read by a respawn loop as a crash and restarted for ever), no start/stop
# timeout bounds, a fixed respawn backoff rather than crash-loop detection.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;

  thin = import ../../providers/services/thin.nix { inherit pkgs lib; };
  entry = thin.entryPointsFor cfg;

  sinit' = pkgs.sinit.override {
    inherit (entry) rcinit rcshutdown;
  };
in
{
  # enabling an implementation is what selects it: this names itself into the contract below,
  # the same way every other providers implementation does when it is enabled.
  options.sinit.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether to boot sinit as PID 1, with the supervision this module builds on top of it.

      Enabling it points {option}`providers.services.backend` at `sinit`, which is what
      actually selects an implementation - so this is a default, and a machine naming a
      backend directly still wins.
    '';
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "sinit" ];
    };
  };

  config = lib.mkMerge [
    # this module supplies an implementation for `providers.services`
    (lib.mkIf config.sinit.enable {
      providers.services.backend = lib.mkDefault "sinit";
    })

    (lib.mkIf (cfg.backend == "sinit") {
      providers.services.supportedFeatures = thin.supportedFeatures;

      # an argv. Activation used to be the first line of rc.init, which is the closest sinit has
      # to a place to put it: sinit itself does nothing but spawn that program and reap.
      # finix-init runs it before sinit is exec'd at all, which is earlier and is the same place
      # every other backend gets it.
      providers.services.exec = [ (lib.getExe' sinit' "sinit") ];

      # sinit only ever acts on this by reacting to a signal sent to pid 1 - unlike every other
      # backend here, there is no command which asks it to shut down directly, only one which
      # asks the kernel to deliver the signal sinit's own sigwait loop is waiting on. It is what
      # then runs rc.shutdown itself, with the right argv, not this.
      #
      # SIGINT is also what the kernel delivers to pid 1 for Ctrl-Alt-Del, and halt is folded
      # into poweroff, the same as runit's: sinit draws no distinction between the two either.
      providers.services.shutdownCommands =
        let
          signal =
            sig:
            pkgs.writeShellScript "sinit-${sig}" ''
              exec ${lib.getExe' pkgs.coreutils "kill"} -s ${sig} 1
            '';
        in
        {
          poweroff = signal "USR1";
          halt = signal "USR1";
          reboot = signal "INT";
        };

      # the state a person wants to read, which is not the fingerprint `switch.list` reports.
      providers.services.ctl.status = thin.statusFor cfg;

      providers.services.switch = thin.switchFor cfg;
    })
  ];
}
