//! The way down.
//!
//! A thin init has no command which asks it to shut down - only a signal, which it answers by
//! spawning one program and telling it which of the two things to do. That one program is this,
//! and the whole reboot-versus-poweroff distinction is carried in its argument.
//!
//! # The bug this replaces
//!
//! In the shell version, the action arrived as `$1` and had to survive to the `case` at the
//! bottom, two hundred lines later. It did not. The loop which waited for the services to go
//! used `set -- "$dir"/*.pid` to test whether a glob had matched anything - correct in
//! isolation, and the idiom POSIX sh leaves you with, since an unmatched glob stays literal -
//! and `set --` replaces the positional parameters. The loop body runs unconditionally at least
//! once, so `$1` was *always* overwritten with a pidfile path, and the `case` therefore always
//! fell through to its default. Every machine asked to reboot powered off instead.
//!
//! It was invisible for a long time because the obvious instrumentation - logging `$1` - was
//! written above the loop, where the argument is still correct.
//!
//! There is nothing clever in the fix. The action is parsed once, into a value with two
//! inhabitants, and there is no mechanism by which a directory read can overwrite it.

use crate::cgroup;
use crate::latch::Latches;
use crate::manifest::Manifest;
use crate::proc;
use std::process::{Command, ExitCode};
use std::time::Duration;

/// What the machine was asked to do. The point of the type is that it is parsed at the top,
/// from the one place the action is known, and read at the bottom.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Reboot,
    /// halt is folded in here, as it is on every thin backend: nothing draws the distinction.
    Poweroff,
}

impl Action {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "reboot" => Some(Action::Reboot),
            "poweroff" | "halt" => Some(Action::Poweroff),
            _ => None,
        }
    }
}

/// Stopping is TERM then KILL on a fixed schedule, the same bargain runit makes for the same
/// reason: nothing here bounds how long a unit may take, so a fixed grace period is the whole
/// policy.
const GRACE: Duration = Duration::from_secs(5);
const POLL: Duration = Duration::from_millis(100);

pub fn run(manifest: &Manifest, action: Action) -> ExitCode {
    let latches = Latches::new(&manifest.latch_dir);

    terminate(&latches);
    cgroup::terminate_sessions();
    await_quiet(&latches);
    kill(&latches);
    cgroup::kill_sessions();

    run_shutdown_side(manifest);

    // `sync` only. The unmount that used to be here is gone, twice over.
    //
    // It was added because going straight to reboot(2) unmounts nothing, so every filesystem is
    // left dirty - btrfs replays its log on the next mount, vfat cannot, and /boot carries
    // "Volume was not properly unmounted" boot after boot. That is still true and still only
    // cosmetic: `fsck.vfat -a` clears it whenever anyone cares.
    //
    // The first attempt hung on the filesystem backing live swap, which neither unmounts nor
    // remounts read-only. `swapoff -a` and a timeout fixed that specific failure and the next
    // shutdown still did not reboot - something in it printed an error and the machine sat
    // there, with no console left to print to. Two attempts, two machines left needing the power
    // button.
    //
    // So: nothing between the kill and reboot(2) that can fail in a way nobody can see. Anything
    // which wants to unmount here needs its progress recorded somewhere that survives a power
    // cycle, because the console scrolls past and the log daemon is already stopped by now.
    unsafe {
        libc::sync();
    }

    enter(action)
}

/// The stop file before the signal, not after.
///
/// The supervise loop restarts anything whose child exits without it, so a TERM delivered first
/// is a service that comes straight back. With the stop file in place the loop breaks instead,
/// and - this is what `await_quiet` depends on - removes the unit's pidfile on its way out.
fn terminate(latches: &Latches) {
    for unit in latches.with_suffix(".pid") {
        let _ = std::fs::write(latches.stop(&unit), "");
        if let Some(pid) = latches.read_pid(&unit) {
            proc::kill_group(pid, libc::SIGTERM);
        }
    }
}

/// Wait for them to be gone, rather than for a fixed five seconds.
///
/// This was an unconditional `sleep 5`, which is what a shutdown cost whether anything was still
/// running or not - and these are daemons being sent SIGTERM, most of which are gone in
/// single-digit milliseconds.
///
/// Two things are waited for. The pidfiles, because the supervise loop removes each one as its
/// child exits, so their absence is the system reporting that it has stopped rather than this
/// assuming it has. And the session cgroups, because the TERM to those is otherwise cosmetic:
/// pidfiles can be gone in a tenth of a second, and killing the compositor a tenth of a second
/// after asking it to leave is not meaningfully different from not asking.
///
/// Same five seconds in the worst case - whatever has not gone is killed next - but a shutdown
/// which goes normally takes about a tenth of one.
fn await_quiet(latches: &Latches) {
    let deadline = std::time::Instant::now() + GRACE;

    while std::time::Instant::now() < deadline {
        let pending = !latches.with_suffix(".pid").is_empty() || cgroup::sessions_pending();
        if !pending {
            return;
        }
        proc::sleep(POLL);
    }
}

fn kill(latches: &Latches) {
    for unit in latches.with_suffix(".pid") {
        if let Some(pid) = latches.read_pid(&unit) {
            proc::kill_group(pid, libc::SIGKILL);
        }
    }
}

/// The shutdown side of the trunk, which `providers/services/shutdown.nix` has already lowered
/// into a single script in trunk order.
///
/// It stays a script. The ordering problem that script exists to solve is a Nix-side one - no
/// init reliably orders units on the way down, so the order is resolved at evaluation time - and
/// nothing about running it is improved by doing it here.
fn run_shutdown_side(manifest: &Manifest) {
    let Some(command) = &manifest.shutdown_command else {
        return;
    };

    let _ = Command::new(&manifest.shell).arg("-c").arg(command).status();
}

/// reboot(2), directly.
///
/// This was `busybox reboot -f`, which is the same syscall with a process in front of it - and a
/// busybox in the closure of every thin-backend system for the sake of two calls. There is
/// nothing left to go wrong between deciding and doing.
///
/// It does not return. If it does, the call failed, and saying so is the only useful thing left:
/// the machine is in no state to carry on and the caller has nothing to retry.
fn enter(action: Action) -> ExitCode {
    let cmd = match action {
        Action::Reboot => libc::RB_AUTOBOOT,
        Action::Poweroff => libc::RB_POWER_OFF,
    };

    unsafe {
        libc::reboot(cmd);
    }

    eprintln!(
        "finix-rc shutdown: reboot(2) for {action:?} returned, which means it failed: {}",
        std::io::Error::last_os_error()
    );
    ExitCode::from(1)
}
