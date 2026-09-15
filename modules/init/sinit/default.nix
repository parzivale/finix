# a providers.services implementation backed by sinit
#
# sinit is not an init in the sense every other backend here has one - it is barely a
# supervisor at all. Read in full (92 lines, suckless.org): it blocks every signal, forks and
# execs exactly one compiled-in command as its only child, then loops on `sigwait` answering
# four signals - reap a zombie (SIGCHLD, or a 30 second alarm as a backstop), spawn a poweroff
# command (SIGUSR1), spawn a reboot command (SIGINT, what the kernel sends PID 1 for
# Ctrl-Alt-Del). If the one child it started exits, sinit does nothing at all - no restart, no
# notice taken. There is no service concept, no dependency graph, no readiness notion.
#
# So unlike runit - which has no native *dependency* system but still supervises and respawns
# every service natively via runsv - this backend gets nothing for free. Everything below is
# built from what sinit actually offers: one long-running child it will never restart, and two
# signals it can be told to answer by running a script.
#
# This is deliberately a minimal first version: no `notify`/`s6` readiness, no `waitFor.pidfile`
# (same reasoning as runit refusing it - the thing it means, the spawned process forking and
# exiting, would be read by a respawn loop as a crash and restarted forever), no start/stop
# timeout bounds, a fixed respawn backoff rather than crash-loop detection.
#
# providers.services.switch turned out not to need a supervisor to reach into after all: every
# job here is already a fully self-contained shell loop - wait on requires, touch a latch,
# supervise - that needs nothing further from rc.init once it is backgrounded. Reaching into a
# running generation is then just running that same script again: launched detached, it
# outlives switch-to-configuration's own shell and is reparented straight to sinit, which reaps
# any of its children regardless of whether rc.init ever knew about this one specifically.
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

  readinessLib = import ../../providers/services/readiness.nix {
    inherit pkgs lib;
    inherit (cfg) readinessPollInterval;
  };
  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  # sinit has no runlevels and nothing resembling a scan directory: a unit either has a job
  # started for it in rc.init, or it does not exist to sinit at all. A shutdown-side unit is
  # simply excluded from that set, the same reasoning as runit's - starting it at boot would
  # not be late, it would be wrong.
  bootSide = lib.filterAttrs (name: unit: !(shutdownLib.onShutdownSide cfg.trunk name unit)) enabled;
  shutdownSide = lib.filterAttrs (name: unit: shutdownLib.onShutdownSide cfg.trunk name unit) enabled;

  # the shutdown side is never started by anything here - it only ever runs once, from
  # rc.shutdown, on the way down - so it is not something switch can start or stop. Reported as
  # already matching whatever this generation says it should be, the same reasoning as runit's:
  # reporting nothing would leave it in the incoming tree forever, and every switch would
  # resolve to "start the shutdown side" for units that can only ever run once, at the very end.
  reportShutdownSide = lib.concatStrings (
    lib.mapAttrsToList (
      name: _: "printf '%s\\t%s\\n' ${name} ${lib.escapeShellArg cfg.switch.fingerprints.${name}}\n"
    ) shutdownSide
  );

  shutdownScript = shutdownLib.scriptFor cfg;

  mkdir = lib.getExe' pkgs.coreutils "mkdir";
  sleep = lib.getExe' pkgs.coreutils "sleep";
  touch = lib.getExe' pkgs.coreutils "touch";
  rm = lib.getExe' pkgs.coreutils "rm";

  # same fix, same reasoning, as runit's: a service which has to claim a controlling terminal
  # needs to be a session leader with none yet, and nothing here gives it one any more than
  # runsv did. `setsid` only forks if it would otherwise be a process group leader
  # (sys-utils/setsid.c), which a freshly-forked job here never is.
  setsid = "${pkgs.util-linux}/bin/setsid";

  latchDir = "/run/providers-services";
  latch = name: "${latchDir}/${name}.ready";
  pidFile = name: "${latchDir}/${name}.pid";
  stopFile = name: "${latchDir}/${name}.stop";

  # the same primitive runit's rewritten waitFor uses - an inotify watch on the latch's
  # directory rather than polling for it, which is the only way anything here learns that a
  # dependency became ready, since nothing observes that natively.
  waitFor = unit: lib.concatMapStrings (dep: readinessLib.waitForPath (latch dep)) unit.requires;

  # sinit does not drop privileges, and neither does anything else this backend uses natively -
  # chpst ships with runit for exactly this, and pulling in one small already-vendored tool
  # beats writing privilege-dropping from scratch for a backend that is trying to be minimal
  # everywhere else.
  chpst = lib.getExe' pkgs.runit "chpst";
  asUser =
    unit:
    if unit.user == null then
      ""
    else
      "${chpst} -u ${unit.user}${lib.optionalString (unit.group != null) ":${unit.group}"} ";

  # a respawn loop, since nothing supervises a service here but this. Backs off a fixed second
  # between attempts rather than detecting a crash loop - the same corner this backend cuts
  # everywhere else for a first version - and stops respawning, rather than looping forever,
  # once rc.shutdown has asked it to by leaving a stop file behind.
  supervise = name: command: ''
    while :; do
      ${command} &
      child=$!
      echo "$child" > ${pidFile name}
      wait "$child"
      ${rm} -f ${pidFile name}
      [ -e ${stopFile name} ] && break
      ${sleep} 1
    done
  '';

  fingerprint = name: "${latchDir}/${name}.fingerprint";

  # one script per unit rather than one job inlined into rc.init - the same shape as runit's
  # run scripts, and for the same underlying reason: something has to be addressable on its
  # own, later, independent of however it was first launched. Every job here is already fully
  # self-contained - wait on requires, touch a latch, supervise - so launching this same script
  # a second time, after boot, is the whole of what switch.activate needs to do.
  jobScript =
    name: unit:
    let
      kind = kindOf unit;
      v = variantOf unit;
      command = "${setsid} ${asUser unit}${v.command or ""}";
    in
    pkgs.writeShellScript "${name}-job" ''
      ${mkdir} -p ${latchDir}
      printf '%s' ${lib.escapeShellArg cfg.switch.fingerprints.${name}} > ${fingerprint name}
      ${waitFor unit}
      ${lib.optionalString (unit.path != [ ]) "export PATH=${lib.makeBinPath unit.path}:\$PATH"}
      ${
        if kind == "anchor" then
          "${touch} ${latch name}"
        else if kind == "oneshot" then
          ''
            ${asUser unit}${v.command}
            ${touch} ${latch name}
          ''
        else if readinessOf unit == "waitFor" then
          ''
            # nothing to latch from once the daemon has been exec'd into, so the wait runs
            # alongside it and latches when whatever it is waiting for is live - the same
            # shape as runit's, and for the same reason: nothing here observes a daemon's
            # readiness on its own either.
            ( ${readinessLib.scriptFor name v.readiness}
              ${touch} ${latch name} ) &
            ${supervise name command}
          ''
        else
          ''
            # `fork` readiness: up the moment it is running, which is what "supervised"
            # means here. `notify` and `s6` never reach this - the contract refuses them
            # against this backend.
            ${touch} ${latch name}
            ${supervise name command}
          ''
      }
    '';

  # named by unit so a name read off stdin - switch.activate's whole input - can reach the
  # script it means. Built over bootSide only: the shutdown side has no script here to launch,
  # the same reason it is excluded from rc.init itself.
  jobDir = pkgs.runCommand "sinit-jobs" { } ''
    mkdir -p $out
    ${lib.concatStrings (
      lib.mapAttrsToList (name: unit: "ln -s ${jobScript name unit} $out/${name}\n") bootSide
    )}
  '';

  # rc.init never returns - sinit does not restart it if it does, so it has to be the thing
  # that stays alive, the way runsvdir is on runit. Everything it starts is backgrounded, so
  # once every job is launched there is nothing left to do but reap them as they finish: a
  # oneshot or anchor's job exits once its latch is touched, and would otherwise zombie under
  # rc.init specifically, since it is rc.init - not sinit - that is its parent for as long as
  # rc.init keeps running. A service's job never exits on its own, so this blocks on whichever
  # finishes first and loops, rather than trying to wait for all of them at once.
  rcInit = pkgs.writeShellScript "rc.init" ''
    ${cfg.activationScript}
    ${mkdir} -p ${latchDir}
    ${lib.concatStrings (lib.mapAttrsToList (name: _: "${jobDir}/${name} &\n") bootSide)}
    while :; do
      wait -n 2>/dev/null || ${sleep} infinity
    done
  '';

  # sinit spawns this as `rc.shutdown reboot` or `rc.shutdown poweroff` - both `rcrebootcmd`
  # and `rcpoweroffcmd` point at the same script, exactly as its own config.def.h default does,
  # differing only in $1. halt is folded into poweroff for the same reason runit's are: nothing
  # here draws the distinction either.
  #
  # Stopping is TERM then KILL on a fixed schedule, the same bargain runit makes for the same
  # reason - nothing here bounds how long a unit may take, so a fixed grace period is the whole
  # policy. `-$pid`, not `$pid`: setsid made each service its own session and process group, so
  # the group is what needs signalling to reach anything it forked.
  rcShutdown = pkgs.writeShellScript "rc.shutdown" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

    for f in ${latchDir}/*.pid; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .pid)
      ${touch} ${latchDir}/"$name".stop
      pid=$(cat "$f")
      kill -TERM -- -"$pid" 2>/dev/null || :
    done

    ${sleep} 5

    for f in ${latchDir}/*.pid; do
      [ -e "$f" ] || continue
      pid=$(cat "$f")
      kill -KILL -- -"$pid" 2>/dev/null || :
    done

    ${lib.optionalString (shutdownScript != null) "${shutdownScript}"}

    case "$1" in
      reboot) exec ${pkgs.busybox}/bin/reboot -f ;;
      *) exec ${pkgs.busybox}/bin/poweroff -f ;;
    esac
  '';

  sinit' = pkgs.sinit.override {
    rcinit = rcInit;
    rcshutdown = rcShutdown;
  };
in
{
  # enabling an implementation is what selects it: this names itself into the contract
  # below, the same way every other providers implementation does when it is enabled.
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
      providers.services.supportedFeatures = {
        # neither is bounded: stopping is TERM then KILL on a fixed schedule, and nothing here
        # times a unit's own start out
        startTimeout = false;
        stopTimeout = false;

        # `waitFor.pidfile` is refused for the same reason it is on runit: it says the daemon
        # forks and the spawned process exits, which this respawn loop would read as a crash and
        # restart forever. `notify` and `s6` are protocols nothing here speaks.
        readiness = [
          "fork"
          "waitFor.socket"
          "waitFor.path"
          "waitFor.check"
        ];

        user = true;
        group = true;
        path = true;
      };

      providers.services.initExecutable = lib.getExe' sinit' "sinit";

      # sinit only ever acts on this by reacting to a signal sent to PID 1 - unlike every other
      # backend here, there is no command which asks it to shut down directly, only one which
      # asks the kernel to deliver the signal sinit's own sigwait loop is waiting on. It is what
      # then runs rc.shutdown itself, with the right argv, not this.
      #
      # SIGINT is also what the kernel delivers to PID 1 for Ctrl-Alt-Del, and halt is folded
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

      providers.services.switch = {
        # every job writes its own fingerprint the moment it starts, whether or not it has
        # actually reached readiness yet - "active" here means "a job for this generation's
        # definition has been launched", the same standard `fork` readiness already treats as
        # good enough for this backend, not "and is done starting".
        list = pkgs.writeShellScript "sinit-list" ''
          ${reportShutdownSide}
          for f in ${latchDir}/*.fingerprint; do
            [ -e "$f" ] || continue
            name=$(${lib.getExe' pkgs.coreutils "basename"} "$f" .fingerprint)
            printf '%s\t%s\n' "$name" "$(${lib.getExe' pkgs.coreutils "cat"} "$f")"
          done
        '';

        # launched detached rather than as a plain background job of this script: this exits as
        # soon as every name on stdin has been started, and a bare `&` job survives that exit
        # only because non-interactive bash does not SIGHUP its children on the way out - true
        # today, but not a guarantee worth depending on. `setsid --fork` forks it into its own
        # session outright, and `disown` drops it from this shell's job table so nothing about
        # this shell ending can reach it either way.
        #
        # a name not in jobDir is the shutdown side, or a unit this generation no longer has -
        # neither is something to start, so it is skipped rather than failing the whole batch.
        #
        # the stop file is cleared here, not by deactivate once the process it names is gone -
        # confirming that and removing the file are two different processes racing each other,
        # and deactivate winning would tell a supervise loop that has not yet checked it to stop
        # respawning something that was never asked to run again. Clearing it immediately before
        # a fresh start has no such race: nothing is still running this name at that point to
        # care whether the file exists.
        activate = pkgs.writeShellScript "sinit-activate" ''
          while read -r unit; do
            [ -e ${jobDir}/"$unit" ] || continue
            ${rm} -f ${latchDir}/"$unit".stop
            ${setsid} --fork ${jobDir}/"$unit" </dev/null >/dev/null 2>&1 &
            disown
          done
        '';

        # a service is stopped exactly as rc.shutdown stops one - the stop file first, so the
        # supervise loop it belongs to does not respawn once the kill below lands, then TERM and
        # KILL on the same fixed schedule, by process group since setsid made each one its own.
        # An anchor or oneshot has no pid file to find, having never been supervised in the first
        # place, so there is nothing to signal - only its latch and fingerprint to take back.
        #
        # the stop file is touched unconditionally, before checking for a pid at all: the loop
        # removes its pid file *before* checking for this one, so a unit between attempts - dead
        # child reaped, backoff sleep not yet over - would otherwise show no pid to signal here,
        # and still respawn once more after this returns, since nothing would have told it to stop.
        #
        # it is deliberately never removed here - see activate, which is where clearing it is
        # actually safe.
        deactivate = pkgs.writeShellScript "sinit-deactivate" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

          while read -r unit; do
            touch ${latchDir}/"$unit".stop

            if [ -e ${latchDir}/"$unit".pid ]; then
              pid=$(cat ${latchDir}/"$unit".pid)
              kill -TERM -- -"$pid" 2>/dev/null || :

              for _ in $(seq 1 50); do
                kill -0 -- -"$pid" 2>/dev/null || break
                sleep 0.1
              done
              kill -KILL -- -"$pid" 2>/dev/null || :
            fi

            rm -f ${latchDir}/"$unit".ready ${latchDir}/"$unit".fingerprint ${latchDir}/"$unit".pid
          done
        '';
      };
    })
  ];
}
