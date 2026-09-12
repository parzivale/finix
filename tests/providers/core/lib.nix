# what the core tests are allowed to say, and the machine they say it on
#
# A core test runs unchanged against every implementation, so it may only assert things the
# contract promises. That rules out most of what the older per-backend tests reach for:
#
#   - console text. "entering runlevel 2" is finit's, "enter stage: /etc/runit/2" is runit's,
#     and waiting for the wrong one does not fail, it hangs until the test times out.
#   - the supervisor's own CLI. initctl, dinitctl, sv and s6-rc each answer a different
#     question in a different vocabulary.
#   - /run/providers-services/<unit>.ready. That is runit's latch mechanism, not the contract's;
#     no other backend writes one.
#
# What is left is what a unit does: files it writes, processes it leaves running, and what
# switch-to-configuration reports. That is enough, and it is the same everywhere.
{ pkgs, lib }:
let
  coreutil = name: lib.getExe' pkgs.coreutils name;

  mkdir = coreutil "mkdir";
  sleep = coreutil "sleep";
  touch = coreutil "touch";
in
rec {
  # not /tmp: the tests inspect this from the driver's shell, and a unit running as somebody
  # else has to be able to write to it too
  markerDir = "/run/core-test";

  # Every script here names its commands absolutely: a unit which sets no `path` inherits
  # whatever the supervisor was given, which under runsvdir is nothing at all - so a bare
  # `mkdir` resolves on finit and silently does not on runit.
  #
  # markerDir itself is a tmpfiles rule in base.nix, so it exists with the right ownership
  # before any unit runs. This only insists on it, for the case where a test declares a unit
  # without that base.
  preamble = ''
    ${mkdir} -p ${markerDir} 2>/dev/null || :
  '';

  # appends its name to a single file, so the file is a record of the order units started in
  recorder =
    name:
    pkgs.writeShellScript "record-${name}" ''
      ${preamble}
      echo ${name} >> ${markerDir}/order
      exec ${sleep} infinity
    '';

  # a long-running process identifiable by name, so `pgrep -f` can find it and its pid can be
  # compared across a switch.
  #
  # not `exec -a`: coreutils here is a multi-call binary which dispatches on argv[0], so
  # renaming the process makes it answer "unknown program" instead of sleeping. Backgrounding
  # and waiting keeps this script's own path - which carries the name - as the process's
  # command line, which is what `pgrep -f` then matches.
  daemon =
    name:
    pkgs.writeShellScript "finix-daemon-${name}" ''
      ${preamble}
      ${sleep} infinity &
      wait
    '';

  # writes down whether `marker` was already there when it started. That is the whole of a
  # readiness assertion: a unit which required something is entitled to find it live.
  observer =
    name: marker:
    pkgs.writeShellScript "observe-${name}" ''
      ${preamble}
      if [ -e ${marker} ]; then
        echo yes > ${markerDir}/${name}.saw
      else
        echo no > ${markerDir}/${name}.saw
      fi
      exec ${sleep} infinity
    '';

  # becomes live only after a delay, so that anything which starts without waiting has time to
  # be caught doing it
  slowDaemon =
    name: delay:
    pkgs.writeShellScript "slow-${name}" ''
      ${preamble}
      ${sleep} ${toString delay}
      ${touch} ${markerDir}/${name}.live
      exec ${sleep} infinity
    '';

  # the portable "the system is up" gate. `running` is the last boot level and has nothing
  # attached to it, so a unit which requires it runs once userspace is up - on every backend,
  # without asking the supervisor anything.
  bootedMarker = "${markerDir}/booted";

  bootedUnit = {
    description = "userspace is up";
    requires = [ "running" ];
    type.oneshot.command = pkgs.writeShellScript "booted" ''
      ${preamble}
      ${touch} ${bootedMarker}
    '';
  };

  # the python the test scripts share, rather than each redefining it
  prelude = ''
    def marker(path):
        code, out = machine.execute(f"cat ${markerDir}/{path}")
        return out.strip() if code == 0 else None


    def pid_of(name):
        # the bracket keeps pgrep's own command line from matching itself
        code, out = machine.execute(f"pgrep -f '[f]inix-daemon-{name}'")
        return out.strip() if code == 0 else None


    def wait_booted():
        machine.wait_until_succeeds("test -e ${bootedMarker}", timeout=240)
  '';
}
