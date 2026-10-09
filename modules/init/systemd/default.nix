# a providers.services implementation backed by systemd
#
# The far end of the range from sinit and nxinit. Those get a contract's worth of supervision
# out of shell, because pid 1 there reaps children and nothing else; this one has to decide
# which of systemd's many ways to say something means what the contract already said, and the
# hard part is restraint rather than emulation.
#
# What systemd is not asked to do here is its usual job. finix already runs eudev, elogind,
# dbus, a syslog daemon and a tmpfiles provider, and those keep their posts - so this backend
# supervises `providers.services` units and nothing else. The alternative, letting systemd own
# the device manager, the login manager, the journal and tmpfiles, is how systemd is meant to
# run and would mean every one of those finix modules growing a "not on systemd" branch. That
# is a larger change to finix than this is.
#
# Which is why the unit tree below is a curated list rather than the 333 units systemd ships.
# Linking the whole tree would also link its `*.target.wants` directories, and those are
# precisely what pull in `systemd-journald`, `systemd-udevd`, `systemd-tmpfiles-setup` and
# `dbus.socket`. Suppressing them again with `/dev/null` masks would make the masks
# load-bearing, and a masked unit fails by quietly doing nothing. Not linking the `.wants`
# directories at all means nothing of systemd's own starts except what the special-unit
# machinery names by `Requires=`, so there is nothing to mask. nixos reaches the same
# conclusion from the other direction - see `upstreamSystemUnits` in
# nixos/modules/system/boot/systemd.nix, which is this list's ancestor.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.providers.services;
  trunk = cfg.trunk;
  scfg = config.systemd;

  enabled = lib.filterAttrs (_: u: u.enable) cfg.units;

  kindOf = unit: lib.head (lib.attrNames unit.type);
  variantOf = unit: unit.type.${kindOf unit};
  readinessOf = unit: lib.head (lib.attrNames (variantOf unit).readiness);

  waitKindOf =
    unit:
    if kindOf unit == "service" && readinessOf unit == "waitFor" then
      lib.head (lib.attrNames (variantOf unit).readiness.waitFor)
    else
      null;

  readinessLib = import ../../providers/services/readiness.nix { inherit pkgs lib; };
  shutdownLib = import ../../providers/services/shutdown.nix { inherit pkgs lib; };

  onShutdownSide = shutdownLib.onShutdownSide trunk;
  bootSide = lib.filterAttrs (n: u: !(onShutdownSide n u)) enabled;

  # the whole shutdown side as one script, in trunk order. The contract lowers it here for
  # every backend because no init orders it reliably - see providers/services/shutdown.nix.
  #
  # systemd is the one init that could have ordered it itself, through units with
  # `Before=shutdown.target`. It still does not, for two reasons: the ordering guarantee the
  # script gives is the same one, and a shutdown side which is units here and a script
  # everywhere else is a second thing to keep in step for no gain.
  shutdownScript = shutdownLib.scriptFor cfg;

  # ---- naming ------------------------------------------------------------------------
  #
  # Everything is prefixed, and it is not cosmetic. The trunk's default levels are `start
  # sysinit basic multi-user running stopped shutdown`, and four of those are systemd special
  # targets: an anchor rendered as `sysinit.target` or `basic.target` would shadow systemd's
  # own, and one rendered as `shutdown.target` would shadow the unit systemd isolates to on the
  # way down - which is `RefuseManualStart=yes` for the reason that implies. trunk.nix warns
  # about exactly this for dinit's `boot`.
  #
  # Prefixing only the colliding names was the other option. It makes a unit's name in the
  # backend unpredictable from its name in the configuration, and it leaves the collision
  # waiting for whoever first declares a unit called `rescue`. Uniform is also what makes
  # `finix-*` a usable glob, which is how `ctl.status` and `switch.list` below scope themselves
  # to our units rather than reporting systemd's forty internal ones.
  prefix = "finix-";

  suffixOf = unit: if kindOf unit == "anchor" then "target" else "service";
  unitOf = name: unit: "${prefix}${name}.${suffixOf unit}";

  # an edge, resolved against the scope the unit lives in. Scoped rather than always against
  # `enabled` because a user's tree is a graph of its own and its units are not in `enabled` at
  # all - the same trap the dinit backend documents at `edgeIn`.
  unitIn =
    scope: name: if scope ? ${name} then unitOf name scope.${name} else "${prefix}${name}.service";

  rootTarget = "${prefix}default.target";
  latchService = "${prefix}shutdown.service";
  firstLevel = lib.head trunk.levels;

  # ---- rendering ---------------------------------------------------------------------

  # systemd quotes with shell rules inside a unit file, so a value with a space in it has to be
  # quoted and one with a quote in it has to be escaped. Unquoted, `Environment=A=b c` sets A to
  # `b` and then fails to parse `c` as an assignment, which systemd reports as a warning and
  # carries on from - so the variable is simply missing at runtime.
  envValue = v: ''"'' + lib.escape [ ''"'' "\\" ] (toString v) + ''"'';

  section =
    heading: lines:
    "[${heading}]\n" + lib.concatMapStrings (l: l + "\n") (lib.filter (l: l != null) lines);

  # the dependencies of a unit, as systemd names them.
  #
  # `Requires=` *and* `After=`, which together are the contract's edge and separately are not.
  # From systemd.unit(5) on Requires=: "If one of the other units fails to activate, and an
  # ordering dependency After= on the failing unit is set, this unit will not be started."
  # Without the `After=`, systemd is free to start both at once and the gate does not exist.
  #
  # `Requires=` rather than `Wants=` because the contract's edge gates on readiness - "A unit
  # starts when, and only when, every unit it requires has become ready" - and `Wants=` does not
  # gate at all: a dependency which failed would leave its dependents starting anyway.
  #
  # And never `BindsTo=`, `PartOf=`, `Upholds=` or `OnFailure=`. The contract is explicit that
  # "nothing in the graph stops anything", and `Requires=` holds that for the cases it names:
  # systemd.unit(5) again - "some unit types may deactivate on their own (for example, a service
  # process may decide to exit cleanly ...), which is not propagated to units having a Requires=
  # dependency". `BindsTo=` is the one that does propagate that, which is why it is not here.
  #
  # One divergence survives and is dealt with in `switch.deactivate`: a dependency which is
  # *explicitly* stopped does propagate.
  depsOf =
    scope: name: unit:
    map (unitIn scope) unit.requires

    # the latch, hung where dinit hangs it and for the same reason. It has to stop after
    # everything else, stop order is the reverse of start order, so it has to start before
    # everything else - and the first trunk level is what everything is transitively behind.
    ++ lib.optional (name == firstLevel && shutdownScript != null) latchService;

  unitSection =
    scope: name: unit:
    let
      deps = depsOf scope name unit;
    in
    section "Unit" (
      [ "Description=${unit.description}" ]
      ++ lib.optionals (deps != [ ]) [
        "Requires=${lib.concatStringsSep " " deps}"
        "After=${lib.concatStringsSep " " deps}"
      ]

      # supervision without end, for a supervised unit.
      #
      # systemd stops restarting after `StartLimitBurst` starts in `StartLimitIntervalSec` -
      # five in ten seconds by default - and leaves the unit `failed`, which is a supervisor
      # quietly deciding to stop supervising. The shell loops in sinit and nxinit respawn
      # forever; this matches them.
      #
      # In [Unit] and not [Service], which is not obvious from the name and is not a free
      # mistake: systemd reports `Unknown key 'StartLimitIntervalSec' in section [Service],
      # ignoring` and carries on with the limiter still armed.
      ++ lib.optional (kindOf unit == "service") "StartLimitIntervalSec=0"
    );

  # `Type=`, which is where readiness lives.
  #
  # `notify` is systemd's own protocol, so it maps straight across. `fork` is "ready the moment
  # it has been forked", which is `Type=simple` exactly.
  #
  # `waitFor.pidfile` becomes `Type=forking` with a `PIDFile=`. That is a slightly stronger
  # claim than the contract makes - forking says the parent exits, where the contract only says
  # a pid file appears - but it is the only shape in which systemd can follow such a daemon's
  # main process at all, and so the only shape in which `Restart=` works for one. The dinit
  # backend reads `waitFor.pidfile` as `bgprocess` on the same reasoning.
  #
  # The other `waitFor` kinds have no native expression - systemd has no "ready when this socket
  # answers" for a service it did not socket-activate - so they stay `Type=simple` and the
  # contract's own readiness command becomes `ExecStartPost=`. That is a real gate rather than a
  # decoration, per systemd.service(5): "the execution of ExecStartPost= is taken into account
  # for the purpose of Before=/After= ordering constraints". So a unit ordered after this one
  # waits for the readiness command to return, which is what the contract asks, and if the
  # command fails the start job fails and the dependents do not start.
  #
  # This is why, unlike dinit, there are no companion readiness units here.
  typeLines =
    name: unit:
    let
      v = variantOf unit;
      wait = waitKindOf unit;
      ready = readinessOf unit;
    in
    if kindOf unit == "oneshot" then
      [
        "Type=oneshot"

        # "ready once it has exited successfully" is a latch, and this is how systemd latches
        # it: without it a completed oneshot goes inactive, and a dependent started later - by a
        # switch, say - would find its `Requires=` unsatisfied and re-run the oneshot.
        "RemainAfterExit=yes"
      ]
    else
      (
        if ready == "notify" then
          [ "Type=notify" ]
        else if wait == "pidfile" then
          [
            "Type=forking"
            "PIDFile=${v.readiness.waitFor.pidfile.file}"
          ]
        else
          [ "Type=simple" ]
      )
      ++ lib.optional (wait != null && wait != "pidfile") (
        "ExecStartPost=${readinessLib.scriptFor name v.readiness}"
      )
      ++ [
        # a service is supervised, which is the whole difference between it and a oneshot.
        "Restart=always"

        # and the respawn must not reach anything downstream of it.
        #
        # This is the directive that lets `Requires=` be the edge at all. A plain
        # `Restart=always` takes the unit through failed/inactive on its way back up, and that
        # transition is a restart as far as propagation is concerned - so every unit requiring
        # this one is restarted too. Measured, not reasoned about: killing a daemon tore down
        # the trunk level above it and restarted two unrelated services behind that.
        #
        # systemd.service(5) on `direct`: "the service transitions to the activating state
        # directly during auto-restart, skipping failed/inactive state ... Dependent units are
        # not notified of these temporary failures." Which is the contract's "if one of them
        # stops, crashes, or restarts, this unit keeps running", in systemd's words.
        "RestartMode=direct"
      ];

  serviceSection =
    name: unit:
    let
      v = variantOf unit;
    in
    section "Service" (
      typeLines name unit
      ++ [ "ExecStart=${v.command}" ]
      ++ lib.optional (unit.user != null) "User=${unit.user}"
      ++ lib.optional (unit.group != null) "Group=${unit.group}"

      # the one capability that needs no wrapper script here. dinit and sinit both write a shell
      # wrapper to get a per-unit PATH; systemd has the directive.
      ++ lib.optional (unit.path != [ ]) "Environment=${envValue "PATH=${lib.makeBinPath unit.path}"}"
      ++ lib.mapAttrsToList (k: v': "Environment=${envValue "${k}=${toString v'}"}") unit.environment
      ++ lib.optional (unit.startTimeout != null) "TimeoutStartSec=${toString unit.startTimeout}"
      ++ lib.optional (unit.stopTimeout != null) "TimeoutStopSec=${toString unit.stopTimeout}"

      # where a unit's own account of itself goes, which has to be said because the usual answer
      # is not here.
      #
      # systemd's default is `StandardOutput=journal`, and there is no journald on this machine -
      # so a unit's stdout is handed to a socket which does not exist and discarded, with one
      # error line per start to say so. A daemon which died explaining why would be explaining it
      # to nothing, which is the one thing a supervisor must not do.
      #
      # `syslog` is not the answer even though finix runs a syslog daemon: systemd deprecated
      # that value in 246 and now treats it as `journal`, so it would mean the same nothing.
      ++ [
        "StandardOutput=${scfg.standardOutput}"
        "StandardError=${scfg.standardOutput}"
      ]
    );

  renderUnit =
    scope: name: unit:
    unitSection scope name unit
    + lib.optionalString (kindOf unit != "anchor") ("\n" + serviceSection name unit);

  # the latch: a unit which does nothing on the way up and runs the shutdown side on the way
  # down. `ExecStop=` rather than a unit per step, because the script is already ordered.
  #
  # `DefaultDependencies=no` with an explicit `Before=`/`Conflicts=shutdown.target` is the
  # documented shape for something that must run during shutdown. With the default dependencies
  # it would also be ordered `After=basic.target`, and so stopped before the units attached to
  # the trunk rather than after them.
  latchText = ''
    [Unit]
    Description=finix shutdown sequence
    DefaultDependencies=no
    Conflicts=shutdown.target
    Before=shutdown.target

    [Service]
    Type=oneshot
    RemainAfterExit=yes
    ExecStart=${lib.getExe' pkgs.coreutils "true"}
    ExecStop=${shutdownScript}
  '';

  # the root. Everything is wanted from here, so that a unit which nothing else requires still
  # starts - in systemd a unit no one pulls in is never started, however complete its own
  # definition is.
  #
  # `Wants=`, through the `.wants` directory, not `Requires=`: a soft pull, so one failing leaf
  # does not fail the boot and no unit becomes impossible to stop while the system runs. The
  # graph's own edges carry every requirement that actually exists; the root adds none. This is
  # the same split dinit makes between `waits-for` on its root and `depends-ms` between units.
  rootText = ''
    [Unit]
    Description=finix default target
  '';

  # ---- the unit tree -----------------------------------------------------------------

  # systemd's own units, curated. No `*.target.wants` directories come with them - see the
  # header - so the only ones that start are the ones something names by `Requires=`, which in
  # practice is the way down.
  #
  # Absent on purpose: everything finix owns (udev, logind, journald, tmpfiles, dbus, sysctl,
  # modules-load, remount-fs) and the sleep units. elogind handles suspend on finix, and a
  # machine with both `systemd-suspend.service` and elogind listening has two things that will
  # answer a lid switch.
  upstreamUnits = [
    # the special targets systemd refers to by name, whether or not anything here uses them.
    # Empty, since nothing is wired into them, and reached immediately for that reason.
    "basic.target"
    "sysinit.target"
    "sockets.target"
    "paths.target"
    "timers.target"
    "slices.target"
    "user.slice"
    "local-fs.target"
    "local-fs-pre.target"
    "remote-fs.target"
    "swap.target"
    "multi-user.target"
    "graphical.target"
    "getty.target"
    "getty-pre.target"
    "network.target"
    "network-pre.target"
    "network-online.target"
    "nss-lookup.target"
    "nss-user-lookup.target"
    "time-set.target"
    "time-sync.target"
    "sound.target"
    "bluetooth.target"
    "printer.target"
    "smartcard.target"

    # the way down, which is the part of systemd's own tree this backend genuinely needs:
    # `poweroff.target` requires `systemd-poweroff.service`, which requires `shutdown.target`,
    # `umount.target` and `final.target`. Leave one out and `systemctl poweroff` fails to
    # enqueue rather than powering the machine off.
    "shutdown.target"
    "umount.target"
    "final.target"
    "exit.target"
    "systemd-exit.service"
    "reboot.target"
    "systemd-reboot.service"
    "poweroff.target"
    "systemd-poweroff.service"
    "halt.target"
    "systemd-halt.service"
    "kexec.target"
    "systemd-kexec.service"

    # somewhere for a failed boot to land. Without these a unit that cannot start leaves the
    # machine with no shell on the console to find out why from.
    "emergency.target"
    "emergency.service"
    "rescue.target"
    "rescue.service"
  ];

  ourUnits =
    lib.mapAttrs' (
      name: unit: lib.nameValuePair (unitOf name unit) (renderUnit bootSide name unit)
    ) bootSide
    // {
      ${rootTarget} = rootText;
    }
    // lib.optionalAttrs (shutdownScript != null) {
      ${latchService} = latchText;
    };

  # what is pulled in from the root: every boot-side unit, and the latch, which nothing else
  # names.
  wanted = lib.attrNames ourUnits;

  # ---- the system bus -----------------------------------------------------------------
  #
  # pid 1 will not connect to the system bus until it believes the bus is there, and it decides
  # that by looking up two units *by name*: `dbus.socket` and `dbus.service` (both strings are
  # in libsystemd-core, and `manager_dbus_is_running` wants the first in its running state and
  # the second in its). finix runs dbus as a contract unit, so systemd sees `finix-dbus.service`
  # and neither name exists - so it never connects, and nothing on the bus can reach pid 1.
  #
  # Which matters because the private socket pid 1 also listens on is root's. An unprivileged
  # `systemctl` goes over the bus, so without this every one of them fails with "The name
  # org.freedesktop.systemd1 was not provided by any .service files" - including the `systemctl
  # start` a session runs to bring up its own service manager, which is the whole user role.
  #
  # The names are supplied rather than the arrangement changed. Letting systemd own the bus -
  # a real `dbus.socket` it binds and a `dbus.service` it activates from that socket - is how
  # systemd expects to run and is the one thing this backend does not do, for dbus the same as
  # for udev, logind, journald and tmpfiles.
  #
  # `dbus.service` is an alias, which costs nothing and is not a fiction: a symlink between two
  # unit files is how systemd spells "the same unit under another name", so the state systemd
  # reads is the real bus's state and not a claim about it.
  busAlias = "${prefix}dbus.service";

  # the socket has no such honest form, because finix's dbus binds its own socket rather than
  # being activated from one - so there is no socket unit to alias. This one exists to reach
  # `SOCKET_RUNNING` and nothing else: an abstract-namespace address, so it occupies no path
  # that dbus or anything else could want.
  #
  # `Service=` names the bus, and that is the whole of the mechanism rather than a detail.
  # `socket_trigger_notify` in systemd's socket.c is what moves a socket into the state pid 1
  # is looking for:
  #
  #   if (SERVICE(other)->state == SERVICE_RUNNING)
  #           socket_set_state(s, SOCKET_RUNNING);
  #
  # `other` there is the unit `Service=` names. So a socket reaches `SOCKET_RUNNING` only when
  # the service it triggers is running, and pointing this at an inert oneshot - which is what it
  # did first, to dodge the two problems below - left it in `SOCKET_LISTENING` for the life of
  # the machine. Which is not a state `manager_dbus_is_running` accepts, so pid 1 never
  # connected, so every unprivileged `systemctl` failed with "The name org.freedesktop.systemd1
  # was not provided by any .service files" - including the one a session runs to start its own
  # manager, which is the whole user role. Nothing logged it: the socket was listening and the
  # bus was running, and the state that was missing was the relation between them.
  #
  # Pointed at the bus, that state is the bus's own and not a claim about it, which is the same
  # property the alias above has.
  #
  # And no ordering of its own, which is what the first attempt got wrong in the other
  # direction. `Service=` already adds `UNIT_BEFORE` with `UNIT_TRIGGERS` - socket.c again -
  # so the socket is ordered before the bus for free. Saying `After=${busAlias}` as well is
  # both halves of the problem that produced the stub: it is a cycle, which systemd resolves by
  # deleting a job from it ("Job finix-dbus.service/start deleted to break ordering cycle
  # starting with dbus.socket/start", the bus never starting and the trunk never completing),
  # and it starts the socket after the bus, which systemd refuses outright - "Socket service %s
  # already active, refusing", `socket_start` declining a socket whose service is up. Starting
  # before the bus is the order that avoids both, and is the order real dbus.socket runs in.
  busStubSocket = ''
    [Unit]
    Description=the name pid 1 looks for before it will use the system bus
    Documentation=man:systemd.socket(5)
    Requires=${busAlias}

    [Socket]
    ListenStream=@finix-systemd-bus-stub
    Service=${busAlias}
  '';

  # and the one file of systemd's that finix's dbus has to read. The units above only make pid 1
  # *try*: it connects, asks for `org.freedesktop.systemd1`, and dbus refuses, because dbus
  # denies `own` by default and the policy permitting root that name is a file systemd ships
  # rather than anything built in. The refusal surfaces as "the name org.freedesktop.systemd1
  # was not provided by any .service files", which reads as the bus never having heard of
  # systemd rather than as a policy decision about a name it has.
  #
  # One file, not `services.dbus.packages = [ ${scfg.package} ]`. The package also carries
  # activation files for login1, hostname1, locale1, resolve1 and the rest - and finix answers
  # login1 with elogind. Handing dbus a second provider for a name elogind already owns is the
  # kind of collision this whole backend is arranged to avoid.
  busPolicy = pkgs.runCommandLocal "finix-systemd-bus-policy" { } ''
    mkdir -p $out/share/dbus-1/system.d
    ln -s ${scfg.package}/share/dbus-1/system.d/org.freedesktop.systemd1.conf \
      $out/share/dbus-1/system.d/
  '';

  # and the action definition, which is the other half of letting a session start its own
  # manager. The rule under `cfg.user.backend` below answers a question polkit has to recognise
  # first: an action id is resolved against the `.policy` files polkit has read, and one it has
  # never heard of is an error rather than a request it can decide. systemd reports that error
  # in the same words as a refusal - "Access denied" - so a missing action file and a denied
  # request are indistinguishable from the caller's side.
  #
  # Only this file, for the reason `busPolicy` takes only one: the package's other actions
  # cover login1, hostname1, resolve1 and the rest, which finix answers with elogind and its
  # own services. The defaults in here are `auth_admin` in all three slots, which is why the
  # rule is needed at all - a session launcher has nobody to prompt.
  polkitActions = pkgs.runCommandLocal "finix-systemd-polkit-actions" { } ''
    mkdir -p $out/share/polkit-1/actions
    ln -s ${scfg.package}/share/polkit-1/actions/org.freedesktop.systemd1.policy \
      $out/share/polkit-1/actions/
  '';

  # only when there is a dbus to speak of. A machine without one has nothing for pid 1 to
  # connect to, and the alias would dangle.
  busNames = bootSide ? dbus;

  unitDir = pkgs.runCommandLocal "finix-systemd-units" { } ''
    mkdir -p $out "$out/${rootTarget}.wants"

    for u in ${lib.escapeShellArgs upstreamUnits}; do
      src=${scfg.package}/example/systemd/system/"$u"
      if [ ! -e "$src" ]; then
        echo "finix systemd backend: ${scfg.package} ships no $u" >&2
        exit 1
      fi
      ln -s "$src" "$out/$u"
    done

    ${lib.concatStrings (
      lib.mapAttrsToList (
        file: text: "ln -s ${pkgs.writeText "finix-unit-${file}" text} $out/${file}\n"
      ) ourUnits
    )}

    # what systemd starts when it is given no unit to start. A symlink rather than `--unit=` in
    # the argv, so that `systemctl isolate default.target` and `systemctl list-dependencies`
    # mean what they usually do.
    ln -s ${rootTarget} $out/default.target

    # the per-user manager template, installed and wanted by nothing: a session starts an
    # instance of it and that session stops it again. See managerText.
    ${lib.optionalString (cfg.user.backend == "systemd") ''
      ln -s ${pkgs.writeText "finix-user-manager.service" managerText} \
        "$out/${managerUnit}.service"
    ''}

    # see the note above busAlias: the two names pid 1 needs before it will use the bus.
    ${lib.optionalString busNames ''
      ln -s ${busAlias} $out/dbus.service
      ln -s ${pkgs.writeText "finix-unit-dbus.socket" busStubSocket} $out/dbus.socket
      ln -s ../dbus.socket "$out/${rootTarget}.wants/dbus.socket"
    ''}

    ${lib.concatMapStrings (u: ''
      ln -s ../${u} "$out/${rootTarget}.wants/${u}"
    '') (lib.filter (u: u != rootTarget) wanted)}
  '';

  # ---- the shell side ----------------------------------------------------------------

  # a unit's name in the configuration is not its name in systemd, and four scripts below need
  # to go between the two. Generated rather than derived in shell, because the suffix depends on
  # the unit's kind and nothing on a running system records that.
  nameMap = pkgs.writeText "finix-systemd-names" (
    lib.concatStrings (lib.mapAttrsToList (name: unit: "${name}\t${unitOf name unit}\n") bootSide)
  );

  systemctl = lib.getExe' scfg.package "systemctl";

  # the fingerprints of the generation that is running, which /run is seeded from at boot and
  # `switch.activate` updates. Not /etc: a switch rewrites that before the engine is asked what
  # is running, so a fingerprint read from there would already be the incoming generation's and
  # would compare equal to itself. The dinit backend documents the same trap at length.
  runFingerprints = "/run/finix-systemd-fingerprints";

  fingerprintDir = pkgs.runCommandLocal "finix-systemd-fingerprints" { } (
    ''
      mkdir -p $out
    ''
    + lib.concatStrings (
      lib.mapAttrsToList (
        name: fp: "printf '%s' ${lib.escapeShellArg fp} > $out/${name}\n"
      ) cfg.switch.fingerprints
    )
  );

  # shared by the scripts below: our units' state, as the contract's four words.
  #
  # `--plain` because without it `list-units` prefixes a failed unit with a bullet, which would
  # land in the name column. `--all` because `list-units` reports only what is loaded and
  # started, and a unit that is loaded and stopped is exactly what the caller wants to hear
  # about.
  stateScript =
    name: scopeArgs:
    pkgs.writeShellScript name ''
      ${systemctl} ${scopeArgs} list-units --all --plain --no-legend 'finix-*' 2>/dev/null |
        while read -r unit _load active sub _rest; do
          # ours, not the configuration's: the root, the latch and the per-user managers are
          # this backend's own bookkeeping and mean nothing to anyone reading a unit list. The
          # manager especially - a user's units are reported in their own tree, so listing the
          # thing that supervises them beside the system's would be a third kind of row.
          case "$unit" in
            ${rootTarget} | ${latchService} | ${managerUnit}*) continue ;;
          esac

          name=''${unit#${prefix}}
          name=''${name%.service}
          name=''${name%.target}

          case "$active" in
            active)
              # a oneshot that ran and stayed - `active (exited)` - is the contract's `done`.
              case "$sub" in
                exited) state=done ;;
                *) state=running ;;
              esac
              ;;
            activating) state=starting ;;
            deactivating) state=stopping ;;
            inactive | failed) state=stopped ;;
            *) state=unknown ;;
          esac

          printf '%s\t%s\n' "$name" "$state"
        done
    '';

  # configuration name -> systemd unit name, for a unit in this generation.
  lookup = ''
    unit_file() {
      ${lib.getExe' pkgs.gawk "awk"} -F'\t' -v n="$1" \
        '$1 == n { print $2; found = 1 } END { exit !found }' ${nameMap}
    }
  '';

  # and for one that is not: a unit being deactivated has been removed from the incoming
  # generation, so it is not in the map above. systemd is asked instead, which knows because it
  # is still running it.
  loaded = scopeArgs: ''
    loaded_file() {
      ${systemctl} ${scopeArgs} list-units --all --plain --no-legend \
        "${prefix}$1.service" "${prefix}$1.target" 2>/dev/null |
        ${lib.getExe' pkgs.gawk "awk"} '{ print $1; exit }'
    }
  '';

  # ---- the user role -----------------------------------------------------------------
  #
  # `systemd --user` is already the shape `user.manager.supervisor.command` asks for: it runs as
  # the user, inside the session, and does not daemonise away from it. It is what
  # `user@.service` runs on a systemd machine, where logind starts it - which is the one thing
  # that cannot happen here, since finix keeps elogind and elogind starts no user managers. The
  # session launcher starts it instead, which is the arrangement every other backend here
  # already has.
  userDir = user: "finix-systemd/user/${user}";

  # the per-user search path, which is the only genuinely awkward part of the user role.
  #
  # `systemd --user` looks in `/etc/systemd/user`, and that is one directory per system rather
  # than one per user - so two users' trees would be the same tree, which is the problem dinit
  # solves with `-d`. systemd has no `-d`. What it has is $SYSTEMD_UNIT_PATH, per systemd(1):
  # "Controls where systemd looks for unit files ... the specified list replaces the usual set of
  # paths."
  #
  # Replaces, so systemd's own user units have to be named too. Without them a user unit with
  # the default dependencies is ordered against a `basic.target` which does not exist, and the
  # whole tree fails to load.
  userUnitPath = user: "/etc/${userDir user}:${scfg.package}/example/systemd/user";

  # ---- the per-user manager ----------------------------------------------------------
  #
  # `systemd --user` will not run in a cgroup it does not own: it creates `init.scope` as a
  # child of wherever it already is, and in a root-owned cgroup that is `Permission denied` and
  # it exits. Nothing in the session can fix that - cgroups(7) is explicit that "the
  # unprivileged delegatee can't place the first process into the delegated subtree; instead,
  # the delegater must place the first process ... into the delegated subtree".
  #
  # elogind looks like it should supply this and does not. It has `session_chown_cgroup_path`
  # and does chown a session cgroup, but in its own named hierarchy under
  # /sys/fs/cgroup/elogind - and `systemd --user` reads the unified hierarchy, the `0::` line of
  # /proc/self/cgroup, which is PID 1's tree and root-owned.
  #
  # So the manager is a system unit with `User=` and `Delegate=`, which is how systemd creates a
  # cgroup and chowns it to the user - the same arrangement as `user@.service`, which this is
  # modelled on. It is deliberately not wanted by anything: the session starts it and the
  # session stops it, because a manager already running when a session begins could have neither
  # the session's environment nor its lifetime.
  managerUnit = "finix-user-manager@";
  managerFor = user: "${managerUnit}${user}.service";

  # instantiated by user name rather than by uid, as `user@.service` is. The polkit rule below
  # compares against `subject.user`, which is a name, so a uid instance would mean resolving one
  # to the other inside a rule that cannot do lookups.

  # $XDG_RUNTIME_DIR has to be in the manager's environment, not merely be a directory that
  # exists. systemd(1) refuses outright without it - "Trying to run as user instance, but
  # $XDG_RUNTIME_DIR is not set" - and the directory half is the unit below in
  # `providers.services.units`. Both halves or neither.
  #
  # It cannot be written into the unit file. The value is /run/user/<uid>; the manager is
  # instantiated by user name, for the reason just above; and a uid is not known at evaluation
  # time, because `users.users.<name>.uid` is `nullOr int` and userborn allocates one on
  # activation when it is null. `%U` is no help either - systemd.unit(5) says it is "the numeric
  # UID of the user running the service manager instance", "not influenced by the User= setting",
  # so in a system unit it is 0 and /run/user/0 is root's.
  #
  # So the lookup happens where `id` can run. It needs no argument: systemd applies `User=`
  # before it runs `ExecStart`, so this is already that user and `id -u` is their own uid.
  #
  # `exec` rather than letting it run as a child, which is the one way to write this and have it
  # look like a timing bug. systemd.service(5) forces `NotifyAccess=main` for a notify service
  # when it would otherwise be `none`, so `READY=1` is only accepted from MAINPID - a forked
  # manager's notification is discarded and the unit sits until `TimeoutStartSec` and fails.
  managerExec = pkgs.writeShellScript "systemd-user-manager" ''
    XDG_RUNTIME_DIR=/run/user/$(${lib.getExe' pkgs.coreutils "id"} -u)
    export XDG_RUNTIME_DIR
    exec ${scfg.package}/lib/systemd/systemd --user
  '';

  # the contract unit which makes that directory, named in one place because the manager orders
  # itself against it below and the two have to stay in step.
  runtimeDirUnit = user: "user-runtime-dir--${user}";

  managerText = ''
    [Unit]
    Description=finix user service manager for %i

    # a manager is not part of any runlevel and must survive one being isolated, the same
    # reasoning upstream gives `user@.service`
    IgnoreOnIsolate=yes

    # $XDG_RUNTIME_DIR has to exist before `systemd --user` looks at it. In practice it already
    # does - the unit is a oneshot attached to `sysinit` and a session starts long after - but
    # that is timing rather than a statement, and timing is what stops being true.
    #
    # `Requires=` with `After=`, which is the pair this backend uses for every edge and for the
    # reason given where they are generated: `Requires=` alone leaves systemd free to start both
    # at once. Not `BindsTo=`, which is what systemd's own `user@.service` uses for this - that
    # propagates a clean exit of the directory unit into stopping the manager, and the policy
    # here is that nothing in the graph stops anything.
    Requires=${prefix}${runtimeDirUnit "%i"}.service
    After=${prefix}${runtimeDirUnit "%i"}.service

    [Service]
    User=%i
    Type=notify

    # the whole point of this unit. `Delegate=` is what makes systemd chown the cgroup, its
    # `cgroup.procs` and its `cgroup.subtree_control` to %i, and `DelegateSubgroup=` puts the
    # manager straight into the `init.scope` it would otherwise have to create for itself.
    Delegate=yes
    DelegateSubgroup=init.scope
    Slice=user-%i.slice

    Environment=SYSTEMD_UNIT_PATH=${userUnitPath "%i"}

    # see managerExec: $XDG_RUNTIME_DIR cannot be written here, so it is resolved and exported
    # by the thing that execs the manager.
    ExecStart=${managerExec}

    # `mixed` rather than the default `control-group`: TERM goes to the manager alone, so it
    # stops her tree itself and in order. The default would TERM every process in the cgroup at
    # once, which is a logout that stops nothing in the order it asked to be stopped in.
    KillMode=mixed
    TimeoutStopSec=120s

    TasksMax=infinity
    KeyringMode=inherit

    StandardOutput=${scfg.standardOutput}
    StandardError=${scfg.standardOutput}
  '';

  # what the session actually runs, and what stops it. The contract's supervisor is a foreground
  # process the launcher owns; the manager is a unit pid 1 owns. So the launcher's child is a
  # client, not the manager.
  #
  # `start --wait` is both halves of the start - systemctl(1): "synchronously wait for started
  # units to terminate again" - so it blocks for exactly as long as the manager runs, which is
  # what the launcher waits on.
  #
  # And `stop` is why `supervisor.stop` exists. Signalling the client says nothing about the job
  # it enqueued, so this used to be a shell script wrapped around the client, trapping TERM and
  # running `systemctl stop` from the handler. The contract asks now, and the wrapper is gone.
  #
  # The launcher still gives its child five seconds before SIGKILL, which is less than
  # `TimeoutStopSec` above - not a leak: `systemctl stop` enqueues a job in pid 1, and the job
  # outlives the client that asked for it, so her tree goes on stopping in order either way.
  managerStart = user: [
    systemctl
    "start"
    "--wait"
    (managerFor user)
  ];
  managerStop = user: [
    systemctl
    "stop"
    (managerFor user)
  ];

  userUnits =
    user: u:
    lib.mapAttrs' (
      name: unit: lib.nameValuePair (unitOf name unit) (renderUnit u.units name unit)
    ) u.units
    // {
      ${rootTarget} = rootText;
    };

  userUnitDir =
    user: u:
    let
      units = userUnits user u;
    in
    pkgs.runCommandLocal "finix-systemd-units-${user}" { } ''
      mkdir -p $out "$out/${rootTarget}.wants"

      ${lib.concatStrings (
        lib.mapAttrsToList (
          file: text: "ln -s ${pkgs.writeText "finix-user-unit-${user}-${file}" text} $out/${file}\n"
        ) units
      )}

      ln -s ${rootTarget} $out/default.target

      ${lib.concatMapStrings (u': ''
        ln -s ../${u'} "$out/${rootTarget}.wants/${u'}"
      '') (lib.filter (u': u' != rootTarget) (lib.attrNames units))}
    '';

  # `systemctl` and the inspection tools, but not the package they come from.
  #
  # `pkgs.systemd` also ships `udevadm`, `loginctl` and `systemd-tmpfiles`, and eudev, elogind
  # and `nixos-compat` each install one of those - so the package as a whole collides three ways,
  # and each collision would be settled by profile priority rather than by anything that knows
  # which of the two should win. `journalctl` is left out for a different reason: there is no
  # journal for it to read.
  systemdTools = pkgs.runCommandLocal "systemd-tools" { } ''
    mkdir -p $out/bin
    for b in systemctl systemd-analyze systemd-cgls systemd-cgtop systemd-run \
             systemd-notify systemd-escape systemd-delta systemd-id128; do
      [ -e ${scfg.package}/bin/"$b" ] && ln -s ${scfg.package}/bin/"$b" $out/bin/"$b"
    done
    true
  '';

  # reaching a user's manager from outside their session.
  #
  # Not `systemctl --user -M <user>@.host`, which is the documented way and needs machined -
  # which finix does not run. $XDG_RUNTIME_DIR instead, which is where the manager's private
  # socket lives; root can open it, and so can that user.
  #
  # The uid is asked for at runtime rather than read out of `config.users.users`, because it may
  # be allocated rather than declared there and `id` knows either way.
  userScript =
    name: user: body:
    pkgs.writeShellScript "${name}-${user}" ''
      uid=$(${lib.getExe' pkgs.coreutils "id"} -u ${lib.escapeShellArg user}) || exit 1
      export XDG_RUNTIME_DIR=/run/user/$uid
      ${body}
    '';
in
{
  options.systemd = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether to boot systemd as PID 1, supervising this configuration's
        {option}`providers.services` units.

        It supervises those and nothing else. finix keeps eudev, elogind, dbus, the syslog
        daemon and the tmpfiles provider, and systemd's own versions of each are not installed -
        so this is the narrower of the two ways to run systemd here, and the one which leaves
        the rest of finix alone.

        Enabling it points {option}`providers.services.backend` at `systemd`, which is what
        actually selects an implementation - so this is a default, and a machine naming a
        backend directly still wins.
      '';
    };

    standardOutput = lib.mkOption {
      type = lib.types.str;
      default = "kmsg";
      example = "null";
      description = ''
        What `StandardOutput=` and `StandardError=` a generated unit gets.

        `kmsg` rather than systemd's own default of `journal`, because this backend runs no
        journald: a unit's output would be handed to a socket which does not exist and
        discarded. The kernel ring buffer is where finix's shutdown sequence already reports
        itself, and `dmesg` reads it back.

        The cost is the kernel's `printk` rate limit, which a chatty daemon will reach. Set
        `null` to discard output on a machine where that matters more, or any other value
        {manpage}`systemd.exec(5)` accepts.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.systemd;
      defaultText = lib.literalExpression "pkgs.systemd";
      description = ''
        The systemd to boot, and to drive with `systemctl`.

        Only some of its binaries are installed - see the comment on
        {option}`environment.systemPackages` in this module. The package as a whole would
        collide with eudev's `udevadm`, elogind's `loginctl` and the `systemd-tmpfiles` shim
        `nixos-compat` installs.
      '';
    };

    # the user scope, which for this backend is the one place the answer is not independent of
    # the system's - by this module's choice rather than systemd's. See the assertions under
    # `cfg.user.backend == "systemd"` below, which say it for a machine that named the backend
    # by hand as well as for one which set this.
    userSupervisor.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Whether a `systemd --user`, started by each user's session, supervises that user's
        units.

        Enabling it points {option}`providers.services.user.backend` at `systemd`, which is
        what actually selects an implementation for that scope - so this is a default, and a
        machine naming a backend directly still wins.

        Requires {option}`systemd.enable`, because this module arranges the user scope out of
        pid 1 systemd - the `/run/systemd/system` marker `systemd --user` looks for, and the
        delegated cgroup its manager unit is given - and {option}`services.polkit.enable`,
        because that manager is a system unit their session has to ask pid 1 to start. Both are
        asserted; see the messages there for what each would take to lift.
      '';
    };
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "systemd" ];
    };
  };

  config = lib.mkMerge [
    (lib.mkIf scfg.enable {
      providers.services.backend = lib.mkDefault "systemd";
    })

    (lib.mkIf scfg.userSupervisor.enable {
      providers.services.user.backend = lib.mkDefault "systemd";
    })

    (lib.mkIf (cfg.backend == "systemd") {
      # all of it bar `s6`, which is a protocol systemd does not speak - a newline on a
      # descriptor the supervisor chose. Refused rather than downgraded to a plain `Type=simple`,
      # which would call a unit ready the moment it was spawned and start everything behind it
      # too early.
      providers.services.supportedFeatures = {
        startTimeout = true;
        stopTimeout = true;

        readiness = [
          "notify"
          "fork"
          "waitFor.socket"
          "waitFor.pidfile"
          "waitFor.path"
          "waitFor.check"
        ];

        user = true;
        group = true;
        path = true;
      };

      # systemd is its own init, and `finix-init` execs it as pid 1 - so it is pid 1 by exec
      # rather than from the kernel, which it does not mind. What it does need is /proc, /sys and
      # a cgroup2 mount, and `providers.services.virtualMounts` has all three in place before
      # this runs.
      providers.services.exec = [ "${scfg.package}/lib/systemd/systemd" ];

      # the generation about to be started, recorded as the running one. Before the exec rather
      # than in activation, which also runs on every switch: rewriting these then would tell the
      # next `list` that whatever is running was already what is being switched into.
      providers.services.pre = [
        {
          op = "copyTree";
          from = fingerprintDir;
          to = runFingerprints;
          writable = true;
        }
      ];

      environment.etc."systemd/system".source = unitDir;

      # see busPolicy: without it pid 1 is on the bus and holds no name there.
      services.dbus.packages = lib.mkIf busNames [ busPolicy ];

      environment.systemPackages = [ systemdTools ];

      providers.services.ctl.status = toString (stateScript "systemd-status" "");

      providers.services.shutdownCommands = {
        poweroff = "${systemctl} poweroff";
        reboot = "${systemctl} reboot";
        halt = "${systemctl} halt";
      };

      providers.services.switch = {
        list = pkgs.writeShellScript "systemd-list" ''
          ${systemctl} list-units --plain --no-legend --state=active 'finix-*' 2>/dev/null |
            while read -r unit _rest; do
              case "$unit" in
                ${rootTarget} | ${latchService}) continue ;;
              esac

              name=''${unit#${prefix}}
              name=''${name%.service}
              name=''${name%.target}

              # systemd decides what is running; the fingerprint only says which definition it
              # was started from, which no supervisor can be asked. So a missing record must not
              # remove the unit from the list - one started by hand has none, and skipping it
              # makes it invisible to the engine. `unknown` cannot equal a real fingerprint, so
              # the pair differs and the unit is reconciled either way.
              fp=${runFingerprints}/"$name"
              if [ -e "$fp" ]; then
                printf '%s\t%s\n' "$name" "$(${lib.getExe' pkgs.coreutils "cat"} "$fp")"
              else
                printf '%s\tunknown\n' "$name"
              fi
            done
        '';

        activate = pkgs.writeShellScript "systemd-activate" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          ${lookup}

          # /etc/systemd/system is a symlink to a store path and activation has just replaced
          # it, so systemd is still holding the outgoing generation's unit files.
          ${systemctl} daemon-reload

          while read -r name; do
            unit=$(unit_file "$name") || {
              echo "systemd-activate: no unit for $name" >&2
              continue
            }

            ${systemctl} start "$unit" || echo "start $name failed" >&2

            # what is now running, recorded where the next switch will look. After the start
            # rather than before, so a unit which failed to start is not claimed as this
            # generation's.
            if [ -e ${fingerprintDir}/"$name" ]; then
              mkdir -p ${runFingerprints}
              cp -f ${fingerprintDir}/"$name" ${runFingerprints}/"$name"
            fi
          done
        '';

        # `--job-mode=ignore-requirements`, which is the one place this backend has to work
        # around systemd rather than use it.
        #
        # `Requires=` is how an edge gates starting, and it carries one thing the contract does
        # not ask for: systemd.unit(5) - "this unit will be stopped (or restarted) if one of the
        # other units is explicitly stopped (or restarted)". A switch stopping a removed unit is
        # exactly an explicit stop, so without this flag reconfiguration would cascade and take
        # down every dependent of whatever was removed - which the engine did not ask for and
        # would not restart.
        #
        # `ignore-requirements` rather than `ignore-dependencies`: it drops the requirement
        # dependencies, which is the cascade, and keeps the ordering ones, so the units the
        # engine did name still stop in the right order.
        deactivate = pkgs.writeShellScript "systemd-deactivate" ''
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH
          ${loaded ""}

          while read -r name; do
            unit=$(loaded_file "$name")
            if [ -z "$unit" ]; then
              rm -f ${runFingerprints}/"$name"
              continue
            fi

            ${systemctl} stop --job-mode=ignore-requirements "$unit" ||
              echo "stop $name failed" >&2

            # no longer running, so no longer this generation's
            rm -f ${runFingerprints}/"$name"
          done

          ${systemctl} daemon-reload
        '';
      };
    })

    # systemd supervising a user's tree, started by their session.
    #
    # One `systemd --user` per session beside pid 1 is two processes, and that is correct rather
    # than redundant: pid 1 began before any session existed and will outlive it, so it can have
    # neither the session's environment nor its lifetime.
    #
    # Unlike every other backend's user role, this one is offered only on a machine which runs
    # systemd as pid 1 as well - a restriction this module chooses rather than one systemd
    # imposes; see the assertion below.
    (lib.mkIf (cfg.user.backend == "systemd") {
      # the one place this backend is narrower than the others, and narrower by choice rather
      # than by anything systemd cannot do.
      #
      # dinit, s6 and runit will supervise a user's tree whatever pid 1 is, because a user
      # supervisor is just a program the session runs. `systemd --user` very nearly is too. It
      # calls `sd_booted()` first and refuses -
      #
      #   Trying to run as user instance, but the system has not been booted with systemd.
      #
      # - but that is `access_nofollow("/run/systemd/system/")` and nothing else. Nothing in the
      # manager inspects pid 1. So the first obstacle is a marker directory which could simply
      # be created, and is not, because `sd_booted()` is how every program linked against
      # libsystemd decides whether this is a systemd machine: faking it tells dbus, polkit and
      # anything else that asks a lie far outside the scope of this module.
      #
      # The second is the substantial one. A user manager needs a cgroup subtree it may write
      # to; upstream delegates one from pid 1 with `Delegate=pids memory cpu` in
      # `user@.service`, and without it the manager comes up and then every unit in the tree
      # dies in `cg_create`. Any init could delegate the same subtree - it is a mkdir and a
      # chown, not a pid 1 power - so this is work somebody could do, in a module which would no
      # longer be built around the `user@` unit below.
      #
      # Until somebody wants that, the user role requires the system role. Asserted rather than
      # left to be discovered from a session which silently has no tree, because the refusal
      # above is printed by a process the session launcher started with its output going nowhere.
      assertions = [
        {
          assertion = cfg.backend == "systemd";
          message = ''
            providers.services.user.backend is "systemd", but providers.services.backend is
            "${cfg.backend}".

            `systemd --user` refuses to start unless /run/systemd/system exists - "the system
            has not been booted with systemd" - and this module does not create that marker
            while something else is pid 1, because every program linked against libsystemd
            reads it as "this is a systemd machine". The manager also needs a cgroup subtree
            delegated to it, which here comes from pid 1 systemd.

            Neither is a property of systemd that cannot be worked around; both are this
            backend's to arrange, and it does not. So either set providers.services.backend =
            "systemd" as well, or name one of the other implementations for the user scope -
            dinit, unlike this one, supervises a user's tree whatever is pid 1.
          '';
        }

        # the session starts a system unit, which an unprivileged process may not do unasked.
        #
        # This is the price of the per-user manager: the cgroup it needs can only be created by
        # PID 1, so the manager has to be a unit, so the session has to ask PID 1 to start it -
        # and systemd asks polkit whether the caller may. The rule below is as narrow as the
        # mechanism allows, one user and one unit, but polkit has to be there to read it.
        #
        # Without it `systemctl start` is refused and the session's whole tree silently does not
        # start, with the refusal going to a stderr nobody reads.
        {
          assertion = config.services.polkit.enable;
          message = ''
            providers.services.user.backend is "systemd", which needs services.polkit.enable.

            A user's manager is a system unit - it is the only way to get a cgroup systemd will
            chown to them, which `systemd --user` requires - so their session has to ask PID 1
            to start it. systemd authorises that through polkit, and this module adds a rule
            allowing each user to start and stop only their own manager.

            With polkit absent the request is refused and the session starts no tree at all.
          '';
        }
      ];

      # exactly one unit, for exactly the user it belongs to. `verb` and `unit` are the details
      # systemd puts on the manage-units action, and `subject.user` is the caller's name - which
      # is why the manager is instantiated by name above rather than by uid.
      services.polkit.extraConfig = ''
        // finix: let a user start and stop their own service manager, and nothing else.
        polkit.addRule(function (action, subject) {
          if (action.id !== "org.freedesktop.systemd1.manage-units") {
            return polkit.Result.NOT_HANDLED;
          }

          var verb = action.lookup("verb");
          if (verb !== "start" && verb !== "stop" && verb !== "restart") {
            return polkit.Result.NOT_HANDLED;
          }

          var unit = action.lookup("unit");
        ${lib.concatMapStrings (user: ''
          if (unit === ${builtins.toJSON (managerFor user)}
              && subject.user === ${builtins.toJSON user}) {
            return polkit.Result.YES;
          }
        '') (lib.attrNames cfg.users)}
          return polkit.Result.NOT_HANDLED;
        });
      '';

      environment.etc = lib.concatMapAttrs (user: u: {
        "${userDir user}".source = userUnitDir user u;
      }) cfg.users;

      environment.systemPackages = [
        systemdTools
        polkitActions
      ];

      # $XDG_RUNTIME_DIR, which `systemd --user` keeps its control socket and its own state in
      # and will not start without.
      #
      # elogind creates it per session through PAM, and on a machine with a login manager that
      # is what happens and this unit finds the work already done. It is here for the machine
      # where it does not - an autologin, a test, anything whose session does not go through PAM
      # - because the failure otherwise is `systemd --user` exiting immediately and the whole
      # tree silently never starting.
      #
      # The same division the dinit backend draws around its control socket directory: it needs
      # root, so it cannot happen inside the session, so it is boot work. Idempotent, and
      # elogind mounting its own tmpfs over the directory later is fine.
      providers.services.units = lib.mapAttrs' (
        user: _:
        lib.nameValuePair (runtimeDirUnit user) {
          description = "runtime directory for ${user}";
          requires = [ "sysinit" ];
          type.oneshot.command = pkgs.writeShellScript "user-runtime-dir-${user}" ''
            uid=$(${lib.getExe' pkgs.coreutils "id"} -u ${lib.escapeShellArg user}) || exit 1
            ${lib.getExe' pkgs.coreutils "mkdir"} -p /run/user/"$uid"
            ${lib.getExe' pkgs.coreutils "chown"} ${lib.escapeShellArg user} /run/user/"$uid"
            ${lib.getExe' pkgs.coreutils "chmod"} 0700 /run/user/"$uid"
          '';
        }
      ) cfg.users;

      # a client, not the manager. The manager has to be a unit so systemd can give it a cgroup
      # of its own, and the contract's supervisor is a process the launcher owns - so what the
      # session runs is `systemctl start --wait`, whose lifetime is the manager's, and what
      # stops it is a `systemctl stop` rather than a signal to that client. See `managerStart`.
      providers.services.user.manager.supervisor.command = managerStart;
      providers.services.user.manager.supervisor.stop = managerStop;

      # taking a subcommand and a unit name, as `dinitctl` does - so the configuration's name
      # has to be turned into systemd's before `systemctl` sees it.
      providers.services.user.ctl =
        user:
        toString (
          userScript "systemd-user-ctl" user ''
            ${loaded "--user"}

            unit=$(loaded_file "$2")
            [ -n "$unit" ] || unit="${prefix}$2.service"
            exec ${systemctl} --user "$1" "$unit"
          ''
        );

      providers.services.user.status =
        user:
        toString (
          userScript "systemd-user-status" user ''
            exec ${stateScript "systemd-user-state" "--user"}
          ''
        );
    })
  ];
}
