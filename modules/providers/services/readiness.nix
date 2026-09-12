# the `waitFor` readiness kinds, as a script which blocks until the unit is live
#
# Imported by the implementations rather than reached through an option, because it is a
# function and every one of them needs the same answer: given a unit's waitFor, a program which
# returns once that unit is genuinely up.
#
# Where a backend has a native mechanism for a kind it should use that instead - finit and
# dinit both observe a forking daemon directly - and fall back to this for the rest. What each
# of them does with the script differs: finit runs it as the unit's companion task, runit
# inside the run script, s6 before notifying on its descriptor. The waiting itself is the same
# everywhere, so it is written once.
{ pkgs, lib }:
let
  # the poll interval, and the reason it is not shorter: a socket check connects, and some
  # daemons log every connection. Ten times a second is responsive enough for a boot and quiet
  # enough not to fill a log with rejected connects.
  interval = "0.1";

  sleep = lib.getExe' pkgs.coreutils "sleep";
  socat = lib.getExe pkgs.socat;
in
{
  # null when the kind needs no script - either the unit reports readiness itself, or the
  # backend is expected to observe it natively
  scriptFor =
    name: readiness:
    let
      kind = lib.head (lib.attrNames readiness);
      waitFor = readiness.waitFor or null;
      wait = if waitFor == null then null else lib.head (lib.attrNames waitFor);
    in
    if kind != "waitFor" then
      null

    else if wait == "check" then
      # the command does its own waiting; returning is the signal
      waitFor.check.command

    else
      pkgs.writeShellScript "wait-${name}" (
        if wait == "socket" then
          ''
            # not `test -e`: the path exists from bind(), and listen() comes after it, so a
            # socket which is demonstrably there can still refuse the next client
            until ${socat} -u OPEN:/dev/null UNIX-CONNECT:${lib.escapeShellArg waitFor.socket.path} 2>/dev/null; do
              ${sleep} ${interval}
            done
          ''

        else if wait == "pidfile" then
          ''
            # the file alone proves nothing - it outlives the process it names, so a stale one
            # from a previous boot would report a daemon which is not running
            while :; do
              if [ -s ${lib.escapeShellArg waitFor.pidfile.file} ]; then
                pid=$(cat ${lib.escapeShellArg waitFor.pidfile.file})
                if kill -0 "$pid" 2>/dev/null; then
                  exit 0
                fi
              fi
              ${sleep} ${interval}
            done
          ''

        else
          ''
            until [ -e ${lib.escapeShellArg waitFor.path.path} ]; do
              ${sleep} ${interval}
            done
          ''
      );
}
