//! What `switch-to-configuration` reaches for, and what `ctl status` prints.
//!
//! There is no control socket here and nothing to ask, so all four of these are derived from the
//! latch directory - which is exactly why the layout in `latch.rs` did not change during the
//! port. These read the same files the shell versions read, and the shell versions could be put
//! back without anything else noticing.

use crate::latch::Latches;
use crate::manifest::Manifest;
use crate::proc;
use std::io::BufRead;
use std::process::{Command, ExitCode};
use std::time::Duration;

const GRACE: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(100);

/// Every unit this generation considers active, with the fingerprint of the definition it was
/// launched from.
///
/// A job writes its fingerprint the moment it starts, whether or not it has reached readiness -
/// "active" here means "a job for this generation's definition has been launched", which is the
/// same standard `fork` readiness already treats as good enough on this backend.
///
/// The shutdown side is reported as already matching whatever this generation says it should be.
/// It is never started by anything here - it runs once, on the way down - so reporting nothing
/// would leave it in the incoming tree forever, and every switch would resolve to "start the
/// shutdown side" for units that can only ever run at the very end.
pub fn list(manifest: &Manifest) -> ExitCode {
    for (name, unit) in &manifest.units {
        if unit.shutdown_side {
            println!("{name}\t{}", unit.fingerprint);
        }
    }

    let latches = Latches::new(&manifest.latch_dir);
    for name in latches.with_suffix(".fingerprint") {
        if let Ok(fingerprint) = std::fs::read_to_string(latches.fingerprint(&name)) {
            println!("{name}\t{fingerprint}");
        }
    }

    ExitCode::SUCCESS
}

/// Start each unit named on stdin.
///
/// A name which is not a boot-side unit of this generation is the shutdown side, or something
/// this generation no longer has. Neither is something to start, so it is skipped rather than
/// failing the whole batch.
///
/// The stop file is cleared here and not by `deactivate` once the process it names is gone:
/// confirming that and removing the file are two different processes racing each other, and
/// deactivate winning would tell a supervise loop which has not yet checked it to stop
/// respawning something that was never asked to run again. Clearing it immediately before a
/// fresh start has no such race - nothing is still running this name at that point to care.
pub fn activate(manifest: &Manifest, manifest_path: &str) -> ExitCode {
    let latches = Latches::new(&manifest.latch_dir);
    if let Err(e) = latches.ensure() {
        eprintln!("finix-rc activate: {}: {e}", manifest.latch_dir);
        return ExitCode::from(1);
    }

    let Ok(exe) = std::env::current_exe() else {
        eprintln!("finix-rc activate: cannot read /proc/self/exe");
        return ExitCode::from(1);
    };

    for name in names_on_stdin() {
        match manifest.units.get(&name) {
            Some(unit) if !unit.shutdown_side => {}
            _ => continue,
        }

        let _ = std::fs::remove_file(latches.stop(&name));

        let mut cmd = Command::new(&exe);
        cmd.arg("job").arg(manifest_path).arg(&name);

        if let Err(e) = proc::spawn_detached(&mut cmd) {
            eprintln!("finix-rc activate: {name}: {e}");
        }
    }

    ExitCode::SUCCESS
}

/// Stop each unit named on stdin, exactly as the shutdown path stops one.
///
/// The stop file is written unconditionally, before checking for a pid at all: the supervise
/// loop removes its pidfile *before* it checks for the stop file, so a unit caught between
/// attempts - dead child reaped, backoff not yet over - would otherwise show no pid to signal
/// here and still respawn once more after this returned, nothing having told it to stop.
///
/// It is deliberately never removed here. See `activate`, which is where clearing it is safe.
///
/// An anchor or oneshot has no pidfile, never having been supervised, so there is nothing to
/// signal - only its latch and fingerprint to take back.
pub fn deactivate(manifest: &Manifest) -> ExitCode {
    let latches = Latches::new(&manifest.latch_dir);

    for name in names_on_stdin() {
        let _ = std::fs::write(latches.stop(&name), "");

        if let Some(pid) = latches.read_pid(&name) {
            proc::kill_group(pid, libc::SIGTERM);

            let deadline = std::time::Instant::now() + GRACE;
            while std::time::Instant::now() < deadline && proc::group_alive(pid) {
                proc::sleep(POLL);
            }

            proc::kill_group(pid, libc::SIGKILL);
        }

        let _ = std::fs::remove_file(latches.ready(&name));
        let _ = std::fs::remove_file(latches.fingerprint(&name));
        let _ = std::fs::remove_file(latches.pid(&name));
    }

    ExitCode::SUCCESS
}

/// The state a person wants to read, which is not the fingerprint `list` reports.
///
/// A `.pid` means a job's process is alive, a `.ready` means it latched, and a `.fingerprint`
/// with neither means a job ran and its process is gone - which for a oneshot is how it is
/// supposed to end up.
pub fn status(manifest: &Manifest) -> ExitCode {
    let latches = Latches::new(&manifest.latch_dir);

    for name in latches.with_suffix(".fingerprint") {
        let state = if Latches::exists(&latches.pid(&name)) {
            "running"
        } else if Latches::exists(&latches.ready(&name)) {
            "done"
        } else {
            "stopped"
        };

        println!("{name}\t{state}");
    }

    ExitCode::SUCCESS
}

fn names_on_stdin() -> Vec<String> {
    std::io::stdin()
        .lock()
        .lines()
        .map_while(Result::ok)
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}
