{
  lib,
  stdenv,
  fetchFromGitHub,

  hareHook,
  writableTmpDirAsHomeHook,
}:

# nxinit, which is the same shape as sinit: block a few signals, exec one child, reap what
# lands on pid 1, and answer a signal each for reboot and poweroff. Everything a service
# manager does - supervision, readiness, ordering, the trunk - is `providers.services`' job
# above it, exactly as it is for sinit.
#
# Pinned to a revision rather than tracking a branch. Upstream is seven commits old and says
# "service supervisor(not yet)" in its own README, so a branch would move under us in ways the
# patch below would not survive quietly.
stdenv.mkDerivation (finalAttrs: {
  pname = "nxinit";
  version = "0.1.0-unstable-2026-10-04";

  src = fetchFromGitHub {
    owner = "bunless";
    repo = "nxinit";
    rev = "91afdfb7dfba1ad5c4a03b709489c3a8d9134eda";
    hash = "sha256-kDuFrR1fjYOZdhwBiJpDjMqqs4fjbf6bbdghVBZrz5c=";
  };

  # The one change that makes it an init rather than a demo.
  #
  # Upstream hardcodes the child: `exec::cmd("/bin/sh")`, no arguments and no way to say
  # otherwise. An init is told what its userspace is by whoever starts it - `init=` on the
  # kernel command line - and `/bin/sh` with no arguments and the console on stdin is an
  # interactive shell, not a boot. There is no way to hand it a generated `rc.init`, which is
  # the whole of how sinit is driven, so no backend is possible without this. argv[1] becomes
  # the command and argv[2..] its arguments.
  #
  # It also drops the 30-second `alarm(30)` reap. That was a safety net under SIGCHLD and is
  # not needed: `reap()` already drains in a `wait4(-1, ..., WNOHANG)` loop until ECHILD, so
  # one CHLD collects every pending child, and a child exiting between the drain and the next
  # `sigwait` leaves CHLD pending so the wait returns at once. What it cost was a wakeup every
  # thirty seconds and an unpredictable upper bound on shutdown.
  #
  # Tested as real pid 1 in a PID namespace rather than only built: argv reaches the child,
  # USR1 reboots, USR2 powers off, and five orphaned grandchildren leave no zombies without
  # the alarm.
  patches = [ ./init-command-from-argv.patch ];

  nativeBuildInputs = [
    hareHook
    writableTmpDirAsHomeHook
  ];

  buildPhase = ''
    runHook preBuild
    hare build -o nxinit ./src
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nxinit "$out/bin/nxinit"
    runHook postInstall
  '';

  meta = {
    description = "A minimal init system for Linux";
    homepage = "https://github.com/bunless/nxinit";
    license = lib.licenses.mit;
    mainProgram = "nxinit";
    # hare itself builds for more than this, but the signal and reboot paths here are
    # Linux-only syscalls.
    platforms = lib.platforms.linux;
  };
})
