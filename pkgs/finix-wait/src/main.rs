//! Block until a unit is live, for the `waitFor` readiness kinds.
//!
//! One binary with a subcommand per kind, rather than a generated shell script per unit. The
//! scripts it replaces were correct about what to wait for and could not be correct about how:
//!
//!   - They polled on a whole-second interval, because that is what `providers.services.`
//!     `readinessPollInterval` could express and what `sleep` takes. A socket whose `listen()`
//!     lands a millisecond after the first check then costs a full second, and on this machine
//!     one of those sat directly in front of the compositor: nix-daemon latched 1.05s after the
//!     level it depends on, which was one failed connect, one `sleep 1`, and one that worked.
//!
//!   - They used inotify to avoid that, and could not close the window it opens. `inotifywait`
//!     was backgrounded and the target re-checked immediately, but nothing says the watch is
//!     established by then - `-qq` silences the line that would have - so a file created in the
//!     gap is missed and the wait runs to the watch's timeout, thirty times the poll interval.
//!
//!   - Every check cost a fork: bash, `dirname`, `inotifywait`, `socat`, `sleep`. With every
//!     dependency edge in the system waiting this way, that is hundreds of processes on the
//!     critical path.
//!
//! So there is no inotify here. The reason to reach for it was that a shell cannot poll cheaply,
//! which is not true of a program that can stat in a microsecond: polling on a short backoff is
//! simpler, has no watch to arm and therefore no window to miss, and is indistinguishable from
//! an event at these timescales. Waiting a second costs about sixty stat calls.

use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

/// Starts tight and backs off to a ceiling. The first attempt is nearly always the one that
/// matters - these are all things that have just been asked to happen - so the first retry is
/// immediate-ish, and the ceiling is what keeps a genuinely absent target from spinning.
const FIRST_DELAY: Duration = Duration::from_millis(1);
const MAX_DELAY: Duration = Duration::from_millis(20);

fn backoff(delay: &mut Duration) {
    sleep(*delay);
    *delay = (*delay * 2).min(MAX_DELAY);
}

/// `[ -e ]`, which follows symlinks: a dangling one is not something a dependent can use.
fn exists(path: &Path) -> bool {
    path.metadata().is_ok()
}

fn wait_path(path: &Path) {
    let mut delay = FIRST_DELAY;
    while !exists(path) {
        backoff(&mut delay);
    }
}

/// The path existing is not the same as the socket accepting: it is there from `bind()` and
/// `listen()` comes after, so a socket which is demonstrably present can still refuse the next
/// client. Nothing about the filesystem separates "not listening yet" from "never going to", so
/// this connects, which is the only thing that answers the question.
fn wait_socket(path: &Path) {
    wait_path(path);

    let mut delay = FIRST_DELAY;
    while UnixStream::connect(path).is_err() {
        backoff(&mut delay);
    }
}

/// The file alone proves nothing - it outlives the process it names, so a stale one from a
/// previous boot would report a daemon which is not running. /proc rather than `kill(pid, 0)`
/// because it answers the same question with no signal sent and nothing to get wrong about
/// permissions, and /proc is mounted before any unit runs.
fn pid_is_live(path: &Path) -> bool {
    let Ok(contents) = std::fs::read_to_string(path) else {
        return false;
    };

    let Ok(pid) = contents.trim().parse::<u32>() else {
        return false;
    };

    pid != 0 && Path::new(&format!("/proc/{pid}")).is_dir()
}

fn wait_pidfile(path: &Path) {
    let mut delay = FIRST_DELAY;
    while !pid_is_live(path) {
        backoff(&mut delay);
    }
}

fn usage() -> ExitCode {
    eprintln!(
        "usage: finix-wait <path|socket|pidfile> PATH

  path     return once PATH exists
  socket   return once PATH exists and accepts a connection
  pidfile  return once PATH names a process which is running"
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let [kind, target] = args.as_slice() else {
        return usage();
    };

    let target = Path::new(target);

    match kind.as_str() {
        "path" => wait_path(target),
        "socket" => wait_socket(target),
        "pidfile" => wait_pidfile(target),
        _ => return usage(),
    }

    ExitCode::SUCCESS
}
