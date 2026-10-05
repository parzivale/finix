{
  lib,
  stdenv,
  fetchFromGitHub,

  hareHook,
  writableTmpDirAsHomeHook,

  # The two commands this init is built around, the same pair `pkgs.sinit.override` takes and
  # for the same reason: suckless-style, pid 1 knows them as constants rather than reading any
  # configuration. nxinit has no config file and no argv parsing, so they are substituted into
  # the source at build time.
  #
  # The defaults are what makes an unconfigured nxinit still do something sensible by hand -
  # a shell as the only child, and no shutdown script, which leaves the direct reboot(2)
  # fallback. A backend overrides both.
  rcinit ? "/bin/sh",
  rcshutdown ? "/bin/false",
}:

# nxinit, which is the same shape as sinit: block a few signals, exec one child, reap what
# lands on pid 1, and answer a signal each for reboot and poweroff. Everything a service
# manager does - supervision, readiness, ordering, the trunk - is `providers.services`' job
# above it, exactly as it is for sinit.
#
# Pinned to a revision rather than tracking a branch. Upstream is seven commits old and says
# "service supervisor(not yet)" in its own README, so a branch would move under the patch in
# ways it would not survive quietly.
stdenv.mkDerivation (finalAttrs: {
  pname = "nxinit";
  version = "0.1.0-unstable-2026-10-04";

  src = fetchFromGitHub {
    owner = "bunless";
    repo = "nxinit";
    rev = "91afdfb7dfba1ad5c4a03b709489c3a8d9134eda";
    hash = "sha256-kDuFrR1fjYOZdhwBiJpDjMqqs4fjbf6bbdghVBZrz5c=";
  };

  # What turns a demo into an init.
  #
  # Upstream hardcodes its only child as `exec::cmd("/bin/sh")` with no arguments, and answers
  # SIGUSR1/SIGUSR2 by calling reboot(2) on the spot. Neither is usable here. The first means
  # there is no way to hand it a generated `rc.init`, which is the whole of how sinit is
  # driven. The second is worse: an immediate syscall with no hook leaves nothing able to stop
  # services, sync, or unmount - every shutdown would be `reboot -f` with dirty filesystems.
  #
  # So both commands become constants substituted below, and a shutdown signal spawns
  # `rcshutdown reboot|poweroff` instead of syscalling. Not waited on, because that script's
  # last act is reboot(2) itself - waiting would deadlock on it - which is exactly how sinit
  # and finix's own rc.shutdown already fit together.
  #
  # The direct syscalls survive as a fallback, reached only when rcshutdown cannot be spawned
  # at all. sinit has no equivalent and would simply sit in its signal loop; going down
  # uncleanly beats hanging, since by that point nothing is left that could stop anything.
  #
  # Also drops the 30-second `alarm(30)` reap. It was a safety net under SIGCHLD and is not
  # needed: `reap()` already drains in a `wait4(-1, ..., WNOHANG)` loop until ECHILD, so one
  # CHLD collects every pending child, and a child exiting between the drain and the next
  # `sigwait` leaves CHLD pending so the wait returns at once. What it cost was a wakeup every
  # thirty seconds and an unpredictable upper bound on shutdown.
  patches = [ ./init-and-shutdown-commands.patch ];

  postPatch = ''
    substituteInPlace src/nxinit.ha \
      --replace-fail '@rcinit@' ${lib.escapeShellArg rcinit} \
      --replace-fail '@rcshutdown@' ${lib.escapeShellArg rcshutdown}
  '';

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
    # hare builds for more than this, but the signal and reboot paths here are Linux-only
    # syscalls.
    platforms = lib.platforms.linux;
  };
})
