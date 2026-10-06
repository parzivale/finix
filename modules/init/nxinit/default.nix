# a providers.services implementation backed by nxinit
#
# nxinit is about 110 lines of Hare (github.com/bunless/nxinit), and it is the same shape as
# sinit: it blocks three signals, forks and execs exactly one compiled-in command as its only
# child, then loops on `sigwait` answering what arrives - reap whatever landed on pid 1
# (SIGCHLD), spawn a shutdown command for reboot (SIGUSR1) or poweroff (SIGUSR2). If the one
# child it started exits, nxinit does nothing at all - no restart, no notice taken. There is no
# service concept, no dependency graph, no readiness notion. Its own README says
# "service supervisor(not yet)".
#
# So this backend gets nothing for free, exactly as sinit's does not, and everything the contract
# promises is built from what nxinit actually offers: one long-running child it will never
# restart, and two signals it can be told to answer by running a program.
#
# That "everything" is `providers/services/thin.nix` and `pkgs/finix-rc`, shared with sinit
# because the two inits present the same surface. It used to be shared by hand instead - this
# module and sinit's were four hundred lines each, generating the same shell twice - which is how
# one shutdown bug came to exist in two backends simultaneously. What is left here is nxinit's
# own: the package, the signal numbering, Ctrl-Alt-Del, and /dev/fd.
#
# Two things upstream does not do are patched in, in pkgs/nxinit:
#
#   - the child is `exec::cmd("/bin/sh")` with no arguments, so there is no way to hand it a
#     generated rc.init. It takes a compiled-in constant now, like sinit's config.def.h.
#   - a shutdown signal calls reboot(2) on the spot, with no hook. That leaves nothing able to
#     stop services, sync or unmount - every shutdown would be `reboot -f` on dirty filesystems.
#     It spawns rcshutdown now and lets that finish the job.
#
# Which is to say this is not usable against upstream as it stands, and the pin in pkgs/nxinit is
# what keeps the patch applying. It is also WIP upstream and has no users; nothing here is proven
# on real hardware, only in a VM and a PID namespace.
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

  # not in nixpkgs, so it comes from this repository's own pkgs/ the way openrc's does. The two
  # commands are substituted into the Hare source at build time, which is the same arrangement
  # `pkgs.sinit.override` makes with config.def.h and for the same reason: pid 1 knows them as
  # constants, there being no configuration file and no argv to read.
  nxinit' = pkgs.callPackage ../../../pkgs/nxinit {
    inherit (entry) rcinit rcshutdown;
  };
in
{
  options.nxinit.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    example = true;
    description = ''
      Whether to boot nxinit as PID 1, with the supervision this module builds on top of it.

      Enabling it points {option}`providers.services.backend` at `nxinit`, which is what
      actually selects an implementation - so this is a default, and a machine naming a
      backend directly still wins.
    '';
  };

  options.providers.services = {
    backend = lib.mkOption {
      type = lib.types.enum [ "nxinit" ];
    };
  };

  config = lib.mkMerge [
    (lib.mkIf config.nxinit.enable {
      providers.services.backend = lib.mkDefault "nxinit";
    })

    (lib.mkIf (cfg.backend == "nxinit") {
      providers.services.supportedFeatures = thin.supportedFeatures;

      providers.services.exec = [ (lib.getExe' nxinit' "nxinit") ];

      # /dev/fd, because this backend cannot exec a shell script without it.
      #
      # Hare's `os::exec` does not use execve(2). `exec::cmd` opens the target - O_PATH - and
      # `exec::exec` runs that descriptor with execveat(2) and AT_EMPTY_PATH. For an ELF that is
      # equivalent; for a `#!` script it is not, because the kernel has no pathname to hand the
      # interpreter and synthesises /dev/fd/N instead. rc.init is a shell script, so bash is
      # exec'd with /dev/fd/3 as its argument and has to open it.
      #
      # Which is fine on a running machine and not fine here. /dev/fd is a symlink udev makes
      # when it takes over /dev - it is in udevd's binary, not in any rule - and udev is a unit
      # rc.init starts. So the symlink appears about half a second after the moment this needs
      # it, and the thing that would create it is downstream of the exec that fails:
      #
      #   finix-init: exec /nix/store/...-nxinit/bin/nxinit
      #   /nix/store/...-bash/bin/bash: /dev/fd/3: No such file or directory
      #
      # sinit never meets this: execv(2) takes a path, so the kernel resolves the shebang against
      # a real filename and /dev/fd is never consulted.
      #
      # Still needed after the port, and now for only two lines of shell: rc.init is a one-line
      # `exec finix-rc init <manifest>` shim, because neither init can be handed a command with
      # arguments. Point rcinit at an ELF - which means giving finix-rc a way to find its
      # manifest without being told - and this op goes away.
      #
      # A `pre` op rather than anything in finix-init itself, which is the distinction that
      # option exists to make - "add an op when a backend needs one, not before". `symlink`
      # unlinks first, so a switch onto a machine that already has one is fine, and `pre` runs
      # after mounts and activation and immediately before the exec, which is exactly the window.
      providers.services.pre = [
        {
          op = "symlink";
          from = "/proc/self/fd";
          to = "/dev/fd";
        }
      ];

      # nxinit only ever acts on this by reacting to a signal sent to pid 1 - there is no command
      # which asks it to shut down directly, only one which asks the kernel to deliver the signal
      # its own sigwait loop is waiting on. It is what then runs rc.shutdown itself, with the
      # right argv, not this.
      providers.services.shutdownCommands =
        let
          signal =
            sig:
            pkgs.writeShellScript "nxinit-${sig}" ''
              exec ${lib.getExe' pkgs.coreutils "kill"} -s ${sig} 1
            '';
        in
        {
          # nxinit's mapping, which is not sinit's: USR1 reboots and USR2 powers off, where sinit
          # takes USR1 for poweroff and SIGINT for reboot. halt folds into poweroff for the same
          # reason it does everywhere else here - nothing draws the distinction.
          #
          # There is no Ctrl-Alt-Del entry because there is nothing to put in one. The kernel
          # delivers SIGINT to pid 1 for that, and nxinit neither blocks nor handles SIGINT - an
          # unhandled signal is not delivered to pid 1 at all, so the key combination does
          # nothing. On sinit it is `reboot`. Worth knowing before using this on a machine whose
          # keyboard is the only way in.
          poweroff = signal "USR2";
          halt = signal "USR2";
          reboot = signal "USR1";
        };

      providers.services.ctl.status = thin.statusFor cfg;

      providers.services.switch = thin.switchFor cfg;
    })
  ];
}
