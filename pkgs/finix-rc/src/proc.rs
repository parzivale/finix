//! The process primitives the shell got from `setsid`, `kill` and `sleep`.
//!
//! All three were a fork each, every time, which on the boot path is hundreds of processes and
//! on the shutdown path is a fork per unit at the moment the machine is least able to afford
//! one. They are all one syscall.

use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::time::Duration;

/// Each service becomes its own session and process group before it execs.
///
/// Same fix, same reasoning, as runit's: a service which has to claim a controlling terminal
/// needs to be a session leader with none yet, and nothing here gives it one. It is also what
/// makes the stop path work at all - `kill(-pgid)` reaches whatever the service forked, and
/// without this every unit would share the job's group and stopping one would stop all of them.
///
/// `pre_exec` rather than a `setsid` binary: it runs in the forked child before exec, which is
/// exactly where the real thing did its work. A fresh fork is never a process group leader, so
/// this cannot fail the way `setsid(2)` does for one that is.
///
/// # Safety
///
/// The closure runs between fork and exec, where only async-signal-safe calls are allowed.
/// `setsid(2)` is one.
pub fn in_new_session(cmd: &mut Command) -> &mut Command {
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    cmd
}

/// Detached from this process entirely: its own session, and nothing of ours to write to.
///
/// What `setsid --fork ... </dev/null >/dev/null 2>&1 & disown` was for. The shell version
/// needed `disown` because a bare `&` job survives its parent's exit only through bash
/// declining to SIGHUP it, which is true today and is not a guarantee. Here the child is in its
/// own session from the first instruction, so nothing about this process ending can reach it.
pub fn spawn_detached(cmd: &mut Command) -> io::Result<Child> {
    in_new_session(cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
}

/// `kill(-pgid, sig)`. The negative pid is the point: it signals the process group, which is
/// what reaches anything the service forked.
///
/// Errors are discarded for the same reason the shell had `2>/dev/null || :` on every one of
/// these - the group is very often already gone, which is the outcome being asked for, and
/// there is nothing to distinguish that from a failure worth reporting.
pub fn kill_group(pgid: i32, signal: i32) {
    unsafe {
        libc::kill(-pgid, signal);
    }
}

/// Whether anything is left in the group. `kill(pgid, 0)` sends nothing and answers exactly
/// that question.
pub fn group_alive(pgid: i32) -> bool {
    unsafe { libc::kill(-pgid, 0) == 0 }
}

pub fn sleep(d: Duration) {
    std::thread::sleep(d);
}

/// Reap whatever has exited, blocking until something does.
///
/// `Ok(true)` means a child was reaped, `Ok(false)` that there are none left to wait for -
/// which is `wait -n` returning non-zero in the shell, and is the case rc.init has to handle
/// by not spinning.
pub fn reap_one() -> bool {
    let mut status: libc::c_int = 0;
    unsafe { libc::wait(&mut status) > 0 }
}
