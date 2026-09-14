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
{
  pkgs,
  lib,
  readinessPollInterval,
}:
let
  # the interval between attempts wherever nothing filesystem-observable applies at all - a
  # socket refusing a connection, or the directory a watched path would live under not
  # existing yet. Not shorter than a second by default because a socket check connects, and
  # some daemons log every connection - see `providers.services.readinessPollInterval`.
  interval = toString readinessPollInterval;

  # a watch is armed a good while before it is expected to fire, so its own timeout is a
  # backstop for whatever arming-then-checking still cannot rule out - the target appearing
  # in the instant before the watch is actually live, or a genuinely missed event - rather
  # than the thing this is meant to hit. Generous, because hitting it is already the unlikely
  # case: ×30 the poll interval, so raising one raises the other proportionally.
  watchTimeout = toString (readinessPollInterval * 30);

  sleep = lib.getExe' pkgs.coreutils "sleep";
  dirname = lib.getExe' pkgs.coreutils "dirname";
  socat = lib.getExe pkgs.socat;
  inotifywait = lib.getExe' pkgs.inotify-tools "inotifywait";
in
rec {
  # blocks until `path` exists. Arms an inotify watch on its parent directory *before*
  # checking whether the path is already there, then waits on that watch - a bare
  # "check, then start watching" would leave a window between the two where a path created
  # in the gap goes unnoticed until the watch's own timeout, rather than being caught at once.
  #
  # The watch runs in the background so the script can check the fast path (already there)
  # without waiting on it first; if the check comes back positive the watch is killed instead
  # of consuming the wait it was armed for. Not `inotifywait -m`: one event is one reason to
  # re-check, and re-checking - not the event itself - is what decides whether the loop is
  # done, since the event which fired may belong to some other file in the same directory.
  waitForPath = path: ''
    target=${lib.escapeShellArg path}
    while [ ! -e "$target" ]; do
      dir=$(${dirname} -- "$target")
      if [ ! -d "$dir" ]; then
        ${sleep} ${interval}
        continue
      fi
      ${inotifywait} -qq -t ${watchTimeout} -e create,moved_to -- "$dir" >/dev/null 2>&1 &
      watcher=$!
      if [ -e "$target" ]; then
        kill "$watcher" 2>/dev/null
        wait "$watcher" 2>/dev/null
        break
      fi
      wait "$watcher"
    done
  '';

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
            ${waitForPath waitFor.socket.path}

            # not `test -e`: the path exists from bind(), and listen() comes after it, so a
            # socket which is demonstrably there can still refuse the next client. Nothing
            # filesystem-observable separates "not listening yet" from "never going to", so
            # this phase stays a short poll rather than a watch - it is expected to be brief,
            # since the socket already exists by the time it starts.
            until ${socat} -u OPEN:/dev/null UNIX-CONNECT:${lib.escapeShellArg waitFor.socket.path} 2>/dev/null; do
              ${sleep} ${interval}
            done
          ''

        else if wait == "pidfile" then
          ''
            file=${lib.escapeShellArg waitFor.pidfile.file}
            while :; do
              # the file alone proves nothing - it outlives the process it names, so a stale
              # one from a previous boot would report a daemon which is not running
              if [ -s "$file" ]; then
                pid=$(cat "$file")
                if kill -0 "$pid" 2>/dev/null; then
                  exit 0
                fi
              fi

              dir=$(${dirname} -- "$file")
              if [ ! -d "$dir" ]; then
                ${sleep} ${interval}
                continue
              fi
              ${inotifywait} -qq -t ${watchTimeout} -e create,modify,moved_to,close_write -- "$dir" \
                >/dev/null 2>&1 &
              watcher=$!
              if [ -s "$file" ]; then
                kill "$watcher" 2>/dev/null
                wait "$watcher" 2>/dev/null
                continue
              fi
              wait "$watcher"
            done
          ''

        else
          waitForPath waitFor.path.path
      );
}
