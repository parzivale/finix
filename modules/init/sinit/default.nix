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

  # the latch carries the moment it was created, because nothing reads its contents and
  # something has to be able to see inside a boot.
  #
  # A waiter tests `[ -e ]` and never looks further, so the file has always been empty - and
  # the only record of when a unit became ready was its mtime. That turns out not to be a
  # measurement on this hardware: every mtime lands on an exact integer second, so a whole
  # boot reads as three or four one-second steps and the structure inside them is invisible.
  # Worse, the realtime clock is set partway through userspace - by the RTC driver, once it
  # probes - so latches written before that point carry a time near zero and cannot be
  # compared with the ones after it at all.
  #
  # /proc/uptime is monotonic, starts at the moment the kernel did, and is good to 10ms. One
  # `cut` per unit, written where a `touch` was, and a boot becomes self-measuring: read the
  # latch directory afterwards and every unit says when it was ready, in one timebase, with
  # no clock jump in the middle of it.
  stamp = name: "${lib.getExe' pkgs.coreutils "cut"} -d' ' -f1 /proc/uptime > ${latch name}";
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

        # the unit's environment, which this backend was dropping on the floor.
        #
        # `providers.services.units.<name>.environment` is part of the contract and four of the
        # six implementations render it; this one never read it, so anything a unit said about
        # its environment was accepted and discarded. That included the HOME the contract now
        # defaults for a unit with a user - which is the whole of why home-manager activation
        # failed here, `cd $HOME` being its first line.
        ${lib.concatStrings (
          lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") unit.environment
        )}
      ${
        if kind == "anchor" then
          "${stamp name}"
        else if kind == "oneshot" then
          ''
            # latched on success, and only on success.
            #
            # The latch is what everything downstream waits for, so touching it unconditionally
            # said "this finished" where it meant "this stopped running". Nothing else observes a
            # oneshot here, so a failure became indistinguishable from a success on every path
            # that mattered - and what that produced was a compositor with no configuration:
            # home-manager activation failed, its latch was touched anyway, greetd started on the
            # strength of it, and niri went looking for a config nothing had linked yet.
            #
            # finit is the one backend where that cannot happen, its tasks not satisfying a
            # dependent when they fail, which is why only this one ever showed it.
            #
            # A failed oneshot now holds its dependents. That is the more useful failure: a boot
            # which stops at the unit that broke, rather than one which carries on and shows you
            # the consequence three steps later.
            if ${asUser unit}${v.command}; then
              ${stamp name}
            else
              echo "${name}: exited non-zero, so ${latch name} is not being touched - anything requiring it waits" >&2
            fi
          ''
        else if readinessOf unit == "waitFor" then
          ''
            # nothing to latch from once the daemon has been exec'd into, so the wait runs
            # alongside it and latches when whatever it is waiting for is live - the same
            # shape as runit's, and for the same reason: nothing here observes a daemon's
            # readiness on its own either.
            #
            # `&&` for the reason the oneshot above has an `if`: a readiness script which gives up
            # - a socket that never appeared, a check that kept failing - has established that the
            # daemon is not ready, and latching on the way out of it would say the opposite.
            ( ${readinessLib.scriptFor name v.readiness} \
                && ${stamp name} ) &
            ${supervise name command}
          ''
        else
          ''
            # `fork` readiness: up the moment it is running, which is what "supervised"
            # means here. `notify` and `s6` never reach this - the contract refuses them
            # against this backend.
            ${stamp name}
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


    # `.stop` before the signal, not after: the supervise loop restarts anything whose child
    # exits without it, so a TERM delivered first is a service that comes straight back. With
    # the latch in place the loop breaks instead, and - this is what the wait below depends on -
    # removes the unit's pidfile on its way out.
    for f in ${latchDir}/*.pid; do
      [ -e "$f" ] || continue
      name=$(basename "$f" .pid)
      ${touch} ${latchDir}/"$name".stop
      pid=$(cat "$f")
      kill -TERM -- -"$pid" 2>/dev/null || :
    done

    # Not shared with the other thin backend, and deliberately not - see below. nxinit's copy
    # of this is the same code; both are Linux-only and the seam they would share is not
    # settled.
    #
    # Factoring it into `shutdownLib` was tried and backed out. It removes a duplicate and
    # cements a Linux assumption into shared code at the same time, which is the wrong trade
    # while finix might grow a BSD. The question that has to be answered first is what the
    # interface is, not where the shell lives:
    #
    #   - there is no portable primitive for "end this login session's process tree". The
    #     cgroup is doing something POSIX has no answer to: a grouping inherited on fork which
    #     `setsid` cannot escape.
    #
    #   - the POSIX session is not it, which is worth recording because it is the obvious
    #     guess. Measured on a running desktop: one elogind login session held 87 processes
    #     across at least nine POSIX sessions - 58 under the compositor's, and a separate one
    #     per terminal and per wrapper, because each calls setsid() for itself. Selecting by
    #     SID reaches a fraction of the tree and there is no way to enumerate the rest.
    #
    #   - the BSD counterpart is the reaper facility - procctl(2), PROC_REAP_ACQUIRE to claim
    #     a subtree and PROC_REAP_KILL to signal all of it - not anything cgroup-shaped.
    #     Linux's nearest relative, PR_SET_CHILD_SUBREAPER, has no kill-the-descendants
    #     operation, which is why cgroups are what gets used here.
    #
    # So if this is ever shared it wants to be an operation with a per-OS implementation
    # rather than a shell fragment with `/sys/fs/cgroup` paths in it. Until someone needs the
    # BSD half, two copies of twenty lines is the cheaper mistake.
    #
    # the session, which the loop above cannot reach.
    #
    # Those pidfiles name process group leaders, and a process group is advisory: greetd's
    # worker starts the user's session in a new one - which is what PAM and dbus-run-session do -
    # so `kill -- -$greetd` signals greetd alone and leaves the compositor, the user's service
    # tree and every application of theirs running. On this machine that is fifty processes, niri
    # among them, still holding /dev/dri at the moment reboot(2) is called. The session has
    # therefore never been stopped on this backend; it has only ever died with the machine.
    #
    # elogind has already put them somewhere that cannot be escaped, which is the part worth
    # using rather than reimplementing: a cgroup per session, /sys/fs/cgroup/<id>, inherited on
    # fork and unaffected by setsid. Nothing in it can get out the way a process group can.
    #
    # TERM by hand rather than `cgroup.kill`, which is SIGKILL only: a compositor wants the
    # chance to release the display before the kernel takes the device out from under it, and
    # finit - which stops services by cgroup and reboots this machine where this does not - is
    # the reason to think that matters here.
    #
    # The glob matches no cgroup this script is in: sinit and its children sit in the root, which
    # has no cgroup.procs of its own to match.
    for procs in /sys/fs/cgroup/*/cgroup.procs; do
      [ -e "$procs" ] || continue
      while read -r p; do
        [ -n "$p" ] || continue
        kill -TERM "$p" 2>/dev/null || :
      done < "$procs"
    done

    # wait for them to be gone, rather than for five seconds.
    #
    # This was `sleep 5`, unconditionally, which is what a shutdown cost whether anything was
    # still running or not - and these are daemons being sent SIGTERM, most of which are gone in
    # single-digit milliseconds. Five seconds of every shutdown spent waiting for nothing.
    #
    # Two things are being waited for. The pidfiles, because the supervise loop removes each one
    # as its child exits, so their absence is the system reporting that it has stopped rather
    # than this script assuming it. And the session cgroups, because the TERM above is otherwise
    # cosmetic: pidfiles can be gone in a tenth of a second, and killing the compositor a tenth
    # of a second after asking it to leave is not meaningfully different from not asking.
    #
    # `read` rather than `[ -s ]`: cgroup.procs is a kernfs file and stats as zero length
    # whatever it contains, so the only way to know whether it is empty is to try to read a line.
    #
    # Same five seconds in the worst case - whatever has not gone is killed below - but a
    # shutdown that goes normally takes about a tenth of one.
    #
    # `set --` because an unmatched glob stays literal: `[ -e "$1" ]` is how to ask whether
    # anything matched at all.
    tries=50
    while [ "$tries" -gt 0 ]; do
      pending=0

      set -- ${latchDir}/*.pid
      [ -e "$1" ] && pending=1

      for procs in /sys/fs/cgroup/*/cgroup.procs; do
        [ -e "$procs" ] || continue
        if read -r _ < "$procs" 2>/dev/null; then
          pending=1
        fi
      done

      [ "$pending" = 0 ] && break
      ${sleep} 0.1
      tries=$((tries - 1))
    done


    for f in ${latchDir}/*.pid; do
      [ -e "$f" ] || continue
      pid=$(cat "$f")
      kill -KILL -- -"$pid" 2>/dev/null || :
    done

    # and the hammer, for anything in a session cgroup that did not take the TERM. One write
    # kills the whole subtree at once, so nothing can fork while the list is being walked - which
    # is the failure mode of reading cgroup.procs and signalling it entry by entry.
    for k in /sys/fs/cgroup/*/cgroup.kill; do
      [ -e "$k" ] || continue
      echo 1 > "$k" 2>/dev/null || :
    done

    ${lib.optionalString (shutdownScript != null) "${shutdownScript}"}

    # `sync` only. The unmount that used to be here is gone, twice over.
    #
    # It was added because `reboot -f` goes straight to reboot(2) and unmounts nothing, so every
    # filesystem is left dirty - btrfs replays its log on the next mount, vfat cannot, and /boot
    # carries "Volume was not properly unmounted" boot after boot. That is still true and still
    # only cosmetic: `fsck.vfat -a` clears it whenever anyone cares.
    #
    # The first attempt hung on /persistent, which backs live swap and so neither unmounts nor
    # remounts read-only. `swapoff -a` and a `timeout` fixed that specific failure and the next
    # shutdown still did not reboot - something in it printed an error and the machine sat
    # there, and with swapoff's and umount's stderr going to /dev/null there was no way to tell
    # which step. Two attempts, two machines left needing the power button.
    #
    # So: nothing between the KILL loop and reboot(2) that can fail in a way nobody can see.
    # Anything that wants to unmount here needs its progress recorded somewhere that survives a
    # power cycle - /persistent, before it is unmounted - because the console scrolls past and
    # syslogd is already dead by this point.
    ${lib.getExe' pkgs.coreutils "sync"}

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

      # an argv. Activation used to be the first line of rc.init, which is the closest sinit has
      # to a place to put it: sinit itself does nothing but spawn that script and reap. finix-init
      # runs it before sinit is exec'd at all, which is earlier and is the same place every other
      # backend gets it.
      providers.services.exec = [ (lib.getExe' sinit' "sinit") ];

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

      # the state a person wants to read, which is not the fingerprint `switch.list` reports.
      #
      # sinit has no control socket and nothing to ask, so state is read from the same files the
      # supervision is built out of: a `.pid` means a job's process is alive, a `.ready` means it
      # latched, and a `.fingerprint` with neither means a job ran and its process is gone -
      # which for a oneshot is how it is supposed to end up.
      providers.services.ctl.status = toString (
        pkgs.writeShellScript "sinit-status" ''
          for f in ${latchDir}/*.fingerprint; do
            [ -e "$f" ] || continue
            name=$(${lib.getExe' pkgs.coreutils "basename"} "$f" .fingerprint)

            if [ -e ${latchDir}/"$name".pid ]; then
              state=running
            elif [ -e ${latchDir}/"$name".ready ]; then
              state=done
            else
              state=stopped
            fi

            printf '%s\t%s\n' "$name" "$state"
          done
        ''
      );

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
