# the providers.services contract, driven on systemd as PID 1
#
# The other backends' tests ask whether the contract can be built out of an init that barely
# has one. This one asks the opposite question: systemd has a vocabulary far larger than the
# contract, several of its words nearly mean what the contract means, and the ways to get this
# wrong are all silent.
#
# So most of what follows is about edges. `Requires=` is what makes an edge gate on readiness,
# and it carries one thing the contract forbids - systemd.unit(5): "this unit will be stopped
# (or restarted) if one of the other units is explicitly stopped (or restarted)" - against the
# contract's "nothing in the graph stops anything". Three subtests below exist only to pin that
# down: a crash, a reconfiguration, and the readiness gate itself. Each of them passes trivially
# on a backend that has no dependency mechanism at all, and each of them is a way this one could
# be quietly wrong.
{
  name = "providers.services-systemd";

  nodes.machine =
    { pkgs, ... }:
    let
      daemon =
        name:
        pkgs.writeShellScript "${name}-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          mkdir -p /run/svc-test
          touch /run/svc-test/${name}.running
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';

      # writes into $XDG_RUNTIME_DIR rather than a world-writable directory, which makes it
      # three assertions in one file: the manager ran this at all, the variable reached her
      # tree, and `id -un` says who it really was.
      userDaemon =
        name:
        pkgs.writeShellScript "${name}-user-daemon" ''
          export PATH=${pkgs.coreutils}/bin:$PATH
          id -un > "$XDG_RUNTIME_DIR"/${name}.user
          exec ${pkgs.coreutils}/bin/sleep infinity
        '';
    in
    {
      services.mdevd.enable = true;

      providers.services.backend = "systemd";

      # the session asks pid 1 to start her manager, which an unprivileged process may not do
      # unasked - so the backend adds a polkit rule and asserts polkit is there to read it.
      services.polkit.enable = true;

      users.users.alice = {
        group = "users";
        home = "/home/alice";
        uid = 3001;
      };

      providers.services.user.backend = "systemd";

      providers.services.users.alice.units.agent = {
        type.service.command = userDaemon "agent";

        # `requires` defaults to the first trunk level, which is a system unit - a user unit
        # has to opt out of it explicitly.
        requires = [ ];
      };

      providers.services.units = {
        early = {
          type.oneshot.command = pkgs.writeShellScript "early" ''
            export PATH=${pkgs.coreutils}/bin:$PATH
            mkdir -p /run/svc-test
            touch /run/svc-test/early.ran
          '';
          requires = [ "start" ];
        };

        alpha = {
          type.service.command = daemon "alpha";
          requires = [ "sysinit" ];
        };

        # a dependent of a service. On this backend it is the subject rather than the scenery:
        # whether it keeps running when alpha crashes, and when alpha is deliberately stopped,
        # is the whole of whether `Requires=` was the right choice.
        beta = {
          type.service.command = daemon "beta";
          requires = [ "alpha" ];
        };

        gamma = {
          type.service.command = daemon "gamma";
          requires = [ "basic" ];
        };

        # the readiness gate, built so that getting it wrong is visible rather than a race.
        #
        # `slow` is up as a process immediately and not ready for three seconds. Its dependent
        # records the time it started. If the gate works, `after-slow` starts after the flag
        # appears; if `ExecStartPost=` were not honoured for ordering - the one documented claim
        # this backend leans on - it would start about three seconds earlier, and the comparison
        # below would catch it.
        slow = {
          requires = [ "sysinit" ];
          type.service = {
            command = pkgs.writeShellScript "slow" ''
              export PATH=${pkgs.coreutils}/bin:$PATH
              mkdir -p /run/svc-test
              ( sleep 3; touch /run/svc-test/slow.listening ) &
              exec sleep infinity
            '';
            readiness.waitFor.path.path = "/run/svc-test/slow.listening";
          };
        };

        after-slow = {
          requires = [ "slow" ];
          type.oneshot.command = pkgs.writeShellScript "after-slow" ''
            export PATH=${pkgs.coreutils}/bin:$PATH
            mkdir -p /run/svc-test
            if [ -e /run/svc-test/slow.listening ]; then
              touch /run/svc-test/after-slow.gated
            else
              touch /run/svc-test/after-slow.too-early
            fi
          '';
        };

        # the shutdown side, at two trunk positions so their order is unambiguous.
        late = {
          requires = [ "stopped" ];
          type.oneshot.command = pkgs.writeShellScript "late" ''
            echo "SYSTEMD-SHUTDOWN-1-late" > /dev/console
          '';
        };

        later = {
          requires = [ "shutdown" ];
          type.oneshot.command = pkgs.writeShellScript "later" ''
            echo "SYSTEMD-SHUTDOWN-2-later" > /dev/console
          '';
        };
      };
    };

  testScript =
    { nodes, ... }:
    ''
      machine.start()

      with subtest("systemd came up as pid 1, having been exec'd rather than booted"):
          # finix-init is what the kernel runs; it execs the argv providers.services.exec names.
          # So systemd is pid 1 by exec, and a systemd which objected to that would not get here.
          machine.wait_until_succeeds("systemctl is-system-running --wait || true", timeout=120)
          machine.succeed("test \"$(readlink /proc/1/exe | grep -c systemd)\" = 1")

      with subtest("the trunk came up in order"):
          for level in ["start", "sysinit", "basic", "multi-user", "running"]:
              machine.wait_until_succeeds(f"systemctl is-active finix-{level}.target")

      with subtest("the trunk did not shadow systemd's own special targets"):
          # four default trunk levels are named after systemd special targets, and `shutdown` is
          # the unit systemd isolates to on the way down. Unprefixed, a trunk level would have
          # replaced it and the machine would not come down at all.
          for level in ["sysinit", "basic", "multi-user"]:
              machine.succeed(f"test -e /etc/systemd/system/finix-{level}.target")
          machine.succeed("systemctl cat shutdown.target | grep -q RefuseManualStart")
          machine.succeed("systemctl cat basic.target | grep -q 'man:systemd.special'")

      with subtest("a oneshot ran, latched, and reads as done rather than stopped"):
          machine.wait_until_succeeds("test -e /run/svc-test/early.ran")
          # RemainAfterExit, without which a later dependent would re-run it
          machine.succeed("systemctl is-active finix-early.service")
          machine.succeed("systemctl show -p SubState --value finix-early.service | grep -q exited")

      with subtest("services are supervised and their dependents released"):
          for svc in ["alpha", "beta", "gamma"]:
              machine.wait_until_succeeds(f"systemctl is-active finix-{svc}.service")
              machine.succeed(f"test -e /run/svc-test/{svc}.running")

      with subtest("an edge gates on readiness, not on the process existing"):
          # the claim under test is systemd.service(5): "the execution of ExecStartPost= is taken
          # into account for the purpose of Before=/After= ordering constraints". Without it,
          # after-slow would have run while slow was still three seconds from listening.
          machine.wait_until_succeeds("test -e /run/svc-test/after-slow.gated", timeout=60)
          machine.fail("test -e /run/svc-test/after-slow.too-early")

      with subtest("a killed service is respawned, and its dependent is untouched"):
          # "Once a unit is running it is unaffected by what happens to the units it required - if
          # one of them stops, crashes, or restarts, this unit keeps running."
          #
          # This is the case `Requires=` gets right on its own and `BindsTo=` would not, which is
          # why the renderer emits no BindsTo anywhere.
          beta_pid = machine.succeed("systemctl show -p MainPID --value finix-beta.service").strip()
          alpha_pid = machine.succeed("systemctl show -p MainPID --value finix-alpha.service").strip()

          machine.succeed(f"kill -KILL {alpha_pid}")
          machine.wait_until_succeeds(
              f"test \"$(systemctl show -p MainPID --value finix-alpha.service)\" != {alpha_pid}"
          )
          machine.wait_until_succeeds("systemctl is-active finix-alpha.service")

          # the point of the subtest: beta never restarted
          machine.succeed(
              f"test \"$(systemctl show -p MainPID --value finix-beta.service)\" = {beta_pid}"
          )

      # Before the switch-stop subtest below, not after it. That one's control assertion stops
      # a unit *without* --job-mode=ignore-requirements on purpose, to show the flag matters -
      # and the stop climbs the trunk, because the level above has the stopped unit as a
      # dependant. Everything attached to that level goes with it, polkit included, and only
      # alpha and beta are put back. A session needs polkit to start her manager at all, so
      # from there this subtest fails for a reason that has nothing to do with it.
      with subtest("a user's tree is started by her session, and not before"):
          # the directory half of $XDG_RUNTIME_DIR. It needs root, so it is boot work rather
          # than something the session can do for itself.
          machine.wait_until_succeeds("test -d /run/user/3001", timeout=90)
          assert machine.succeed("stat -c %U /run/user/3001").strip() == "alice"

          # her manager is a system unit, because only pid 1 can make the cgroup it needs - but
          # one nothing wants, so it stays stopped until a session asks for it. A manager
          # already running when a session begins could have neither its environment nor its
          # lifetime.
          machine.fail("systemctl is-active finix-user-manager@alice.service")
          machine.fail("test -e /run/user/3001/agent.user")

          # what greetd does: the launcher, as her, with the session as its payload. No
          # --session-env, there being no compositor here to wait for.
          machine.succeed(
              "setpriv --reuid=3001 --regid=100 --clear-groups "
              "${nodes.machine.config.providers.services.user.sessionLauncher} "
              "--user alice -- sleep infinity >/run/session-launch.log 2>&1 &"
          )

          # the launcher reports what it could not do on stderr and nowhere else, so it is kept
          # rather than discarded - without it every failure in here looks like a bare timeout.
          machine.sleep(10)
          print(machine.succeed("cat /run/session-launch.log || true"))

          # DIAGNOSTIC, to be removed. pid 1 will not connect to the system bus until it finds
          # units named dbus.socket and dbus.service in the right states; these print what those
          # states actually are, rather than what they were inferred to be.
          print(machine.succeed("systemctl list-units --all --no-legend 'dbus*' 'finix-bus-stub*' || true"))
          print(machine.succeed("systemctl show -p Id -p Names -p ActiveState -p SubState dbus.service || true"))
          print(machine.succeed("systemctl show -p Id -p Names -p ActiveState -p SubState dbus.socket || true"))
          print(machine.succeed("systemctl status dbus.socket 2>&1 || true"))
          print(machine.succeed("ls -l /run/dbus/ || true"))
          print(machine.succeed(
              "dbus-send --system --dest=org.freedesktop.DBus --print-reply --type=method_call "
              "/ org.freedesktop.DBus.ListNames 2>&1 | grep -c systemd1 || true"
          ))

          # pid 1 requests its bus name with sd_bus_request_name_async() and no callback, so a
          # refusal is silent on that side, and dbus does not log ownership denials either.
          # Debug logging is the only thing that says which of the two is happening; restarting
          # the bus is what re-triggers the check, since manager_recheck_dbus() runs on unit
          # state changes.
          machine.succeed("systemctl log-level debug")
          machine.succeed("systemctl restart finix-dbus.service || true")
          machine.sleep(5)
          print(machine.succeed("systemctl start finix-user-manager@alice.service 2>&1 || true"))
          print(machine.succeed(
              "dbus-send --system --dest=org.freedesktop.DBus --print-reply --type=method_call "
              "/ org.freedesktop.DBus.ListNames 2>&1 | grep -c systemd1 || true"
          ))

          # the manager came up, which is most of what this subtest is for. `systemd --user`
          # refuses to start without $XDG_RUNTIME_DIR in its environment - "Trying to run as
          # user instance, but $XDG_RUNTIME_DIR is not set" - and that cannot be written into
          # the unit, because the value holds a uid and the unit is instantiated by name. So it
          # is resolved by the thing that execs the manager, and this is the assertion that it
          # is resolved at all.
          machine.wait_until_succeeds(
              "systemctl is-active finix-user-manager@alice.service", timeout=90
          )

          # and her unit ran, as her. Written into $XDG_RUNTIME_DIR rather than somewhere
          # world-writable, so its existence also says the variable reached her tree and not
          # just the manager.
          machine.wait_until_succeeds("test -e /run/user/3001/agent.user", timeout=90)
          assert machine.succeed("cat /run/user/3001/agent.user").strip() == "alice"

      # Ending the session is deliberately not asserted here. Stopping a manager is the one
      # part of the user role this backend cannot express through the contract as it stands -
      # `user.manager.supervisor` has only `command`, and the launcher stops a supervisor by
      # signalling the process it spawned, which a unit pid 1 owns is not. What stands in for
      # it is a shell shim, and that shim is what a `supervisor.stop` option would delete. The
      # teardown assertion belongs with that change rather than pinning the shim in place.

      with subtest("stopping a unit the way a switch does not take its dependents down"):
          # the one place `Requires=` diverges from the contract: an *explicit* stop does
          # propagate. switch.deactivate passes --job-mode=ignore-requirements for exactly this,
          # and this is the assertion that the flag does what it is relied on to do.
          beta_pid = machine.succeed("systemctl show -p MainPID --value finix-beta.service").strip()

          machine.succeed(
              "systemctl stop --job-mode=ignore-requirements finix-alpha.service"
          )
          machine.succeed("systemctl is-active finix-alpha.service | grep -q inactive || true")
          machine.fail("systemctl is-active finix-alpha.service")

          # beta required alpha and is still running, which is the contract
          machine.succeed("systemctl is-active finix-beta.service")
          machine.succeed(
              f"test \"$(systemctl show -p MainPID --value finix-beta.service)\" = {beta_pid}"
          )

          # and without the flag it would not have been - the control for the assertion above
          machine.succeed("systemctl start finix-alpha.service")
          machine.wait_until_succeeds("systemctl is-active finix-alpha.service")
          machine.succeed("systemctl stop finix-alpha.service")
          machine.fail("systemctl is-active finix-beta.service")

          # put it back for the shutdown subtest
          machine.succeed("systemctl start finix-alpha.service finix-beta.service")
          machine.wait_until_succeeds("systemctl is-active finix-beta.service")

      with subtest("initctl reports the configuration's names and the contract's words"):
          # `initctl list` is a TREE/UNIT/STATE table, so the unit is the second column
          machine.succeed("initctl list > /tmp/units")
          machine.succeed("awk '{print $2}' /tmp/units | grep -qx alpha")

          # the configuration's name, not finix-alpha.service: a reader of this table should never
          # have to know how the selected backend spells things
          machine.fail("grep -q finix- /tmp/units")

          # and this backend's own bookkeeping - the root target and the shutdown latch - stays
          # out of it
          machine.fail("awk '{print $2}' /tmp/units | grep -qx default")
          machine.fail("awk '{print $2}' /tmp/units | grep -qx shutdown")
          machine.wait_until_succeeds("initctl status alpha > /tmp/st; grep -q running /tmp/st")
          machine.succeed("initctl status early > /tmp/st2; grep -q done /tmp/st2")

      with subtest("shutdown runs the shutdown side, in trunk order"):
          # `initctl poweroff`, which resolves to `systemctl poweroff` here, rather than
          # machine.shutdown(): the contract's own command is what asks a backend to stop, and
          # using it is also the check that shutdownCommands reaches something real.
          #
          # The shutdown side is one script, hung off finix-shutdown.service's ExecStop. That unit
          # is ordered before everything else on the way up, so it stops after everything else on
          # the way down - which is what the latch means.
          machine.execute("(initctl poweroff &) >/dev/null 2>&1", check_return=False)

          machine.wait_for_console_text("SYSTEMD-SHUTDOWN-1-late")
          machine.wait_for_console_text("SYSTEMD-SHUTDOWN-2-later")

          machine.wait_for_shutdown()
    '';
}
