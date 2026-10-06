//! The supervision a thin init does not have.
//!
//! sinit is 92 lines and nxinit about 110: each blocks signals, execs exactly one child, and
//! answers a handful of signals by spawning a shutdown program. Neither has a service concept, a
//! dependency graph or a readiness notion, and neither restarts the one child it started. So a
//! `providers.services` implementation on top of one of them gets nothing for free, and
//! everything the contract promises - ordering, readiness, supervision, stopping, switching,
//! reporting - has to be built out of what is actually on offer: one long-running child, and two
//! signals.
//!
//! That used to be generated shell, two copies of it, one per backend. This is the same design
//! as a program:
//!
//!   `init`        the long-running child. Launches every job, then reaps.
//!   `job`         one unit: wait on requires, latch, supervise.
//!   `shutdown`    the signal's answer: stop everything, then reboot(2) or poweroff.
//!   `list`        which generation each running unit was launched from, for `switch`.
//!   `activate`    start the units named on stdin.
//!   `deactivate`  stop the units named on stdin.
//!   `status`      what `ctl status` prints.
//!
//! Nothing here is a daemon the others talk to. Each subcommand reads the same directory of
//! latch files and the same manifest, which is what lets `activate` start a unit long after boot
//! without anything to ask permission from. See `latch.rs` for that directory, which the port
//! deliberately left alone.
//!
//! # Why this is a program now
//!
//! Not because the shell was slow - it was not, and the measurement which chose this backend in
//! the first place was taken against the shell version. It is because the shell could not hold a
//! value. The reboot-versus-poweroff distinction travelled two hundred lines as `$1`, and a
//! `set --` used to test whether a glob had matched - the idiom POSIX sh leaves you with -
//! silently overwrote it, so every machine asked to reboot powered off instead. See
//! `shutdown.rs`.
//!
//! The second reason is that there were two copies. Both backends present the same surface, so
//! the supervision on top of them was the same shell either way, and it was maintained by hand
//! in parallel - which is how one bug became two.

mod cgroup;
mod init;
mod job;
mod latch;
mod manifest;
mod proc;
mod shutdown;
mod switch;

use manifest::Manifest;
use std::process::ExitCode;

fn usage() -> ExitCode {
    eprintln!(
        "usage: finix-rc <subcommand> MANIFEST [ARG]

  init         MANIFEST          start every unit, then reap. Does not return.
  job          MANIFEST UNIT     run one unit: wait, latch, supervise.
  shutdown     MANIFEST ACTION   stop everything, then reboot or poweroff.
  list         MANIFEST          unit<TAB>fingerprint, for switch.
  activate     MANIFEST          start the units named on stdin.
  deactivate   MANIFEST          stop the units named on stdin.
  status       MANIFEST          unit<TAB>running|done|stopped."
    );
    ExitCode::from(2)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let (subcommand, manifest_path, rest) = match args.as_slice() {
        [subcommand, manifest_path, rest @ ..] => (subcommand.as_str(), manifest_path, rest),
        _ => return usage(),
    };

    let manifest = match Manifest::load(manifest_path) {
        Ok(manifest) => manifest,
        Err(e) => {
            eprintln!("finix-rc: {e}");
            return ExitCode::from(1);
        }
    };

    match (subcommand, rest) {
        ("init", []) => init::run(&manifest, manifest_path),
        ("job", [unit]) => job::run(&manifest, unit),

        // The action is parsed here, once, and carried as a value from this line to the syscall.
        // Everything about this subcommand's existence is downstream of that having been a
        // string living in `$1` instead.
        ("shutdown", [action]) => match shutdown::Action::parse(action) {
            Some(action) => shutdown::run(&manifest, action),
            None => {
                eprintln!("finix-rc shutdown: unknown action '{action}' - expected reboot, poweroff or halt");
                usage()
            }
        },

        ("list", []) => switch::list(&manifest),
        ("activate", []) => switch::activate(&manifest, manifest_path),
        ("deactivate", []) => switch::deactivate(&manifest),
        ("status", []) => switch::status(&manifest),

        _ => usage(),
    }
}
