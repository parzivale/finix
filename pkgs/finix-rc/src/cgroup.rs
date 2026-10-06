//! Ending a login session's process tree, which the pidfiles cannot reach.
//!
//! The `.pid` files name process group leaders, and a process group is advisory: greetd's worker
//! starts the user's session in a new one - which is what PAM and `dbus-run-session` do - so
//! signalling the service's group reaches greetd alone and leaves the compositor, the user's
//! service tree and every application of theirs running. On a desktop that is fifty processes,
//! the compositor among them, still holding /dev/dri at the moment reboot(2) is called.
//!
//! elogind has already put them somewhere that cannot be escaped, which is the part worth using
//! rather than reimplementing: a cgroup per session, inherited on fork and unaffected by
//! `setsid`. Nothing in it can get out the way a process group can.
//!
//! The POSIX session is *not* a substitute, which is worth recording because it is the obvious
//! guess. Measured on a running desktop: one elogind login session held 87 processes across at
//! least nine POSIX sessions - 58 under the compositor's, and a separate one per terminal and
//! per wrapper, because each calls `setsid()` for itself. Selecting by SID reaches a fraction of
//! the tree and there is no way to enumerate the rest.
//!
//! # Why this is a module rather than two copies of a shell fragment
//!
//! It used to be duplicated between the two thin backends on purpose. The reasoning was that
//! factoring it would cement a Linux assumption into shared code while finix might still grow a
//! BSD, and that the question to answer first was what the *interface* is - because the BSD
//! counterpart is the reaper facility, `procctl(2)` with `PROC_REAP_ACQUIRE` and
//! `PROC_REAP_KILL`, which is not cgroup-shaped at all. Linux's nearest relative,
//! `PR_SET_CHILD_SUBREAPER`, has no kill-the-descendants operation, which is why cgroups are
//! what gets used here.
//!
//! That reasoning asked for "an operation with a per-OS implementation rather than a shell
//! fragment with /sys/fs/cgroup paths in it". This is that: one function, named for what it
//! does rather than how, with the Linux implementation behind a `cfg`. A BSD port adds a second
//! body here and changes nothing that calls it.

#[cfg(target_os = "linux")]
use std::fs;
#[cfg(target_os = "linux")]
use std::path::{Path, PathBuf};

/// The cgroup this process is in, which everything below must skip.
///
/// Without it the sweep signals itself: a VM with no elogind has no session cgroups, the
/// directory read then finds whatever top-level cgroups do exist, and the shutdown TERMs its own
/// process and stops there - the marker before the loop printed, the one after it never ran. On
/// a desktop it happens to be safe, pid 1 and its children sitting in the root cgroup which has
/// no `*/cgroup.procs` of its own, but that is a property of the layout rather than anything
/// this asked for.
#[cfg(target_os = "linux")]
fn own_cgroup() -> Option<PathBuf> {
    let text = fs::read_to_string("/proc/self/cgroup").ok()?;
    // "0::/user.slice/..." - the path is everything after the second colon.
    let rel = text.lines().next()?.splitn(3, ':').nth(2)?.trim();
    Some(PathBuf::from(format!("/sys/fs/cgroup{rel}")))
}

#[cfg(target_os = "linux")]
fn session_cgroups() -> Vec<PathBuf> {
    let own = own_cgroup();
    let Ok(entries) = fs::read_dir("/sys/fs/cgroup") else {
        return Vec::new();
    };

    entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("cgroup.procs").exists())
        .filter(|p| own.as_deref() != Some(p.as_path()))
        .collect()
}

/// The pids in one cgroup.
///
/// `cgroup.procs` is a kernfs file and stats as zero length whatever it contains, so its size
/// says nothing and the only way to know whether it is empty is to read it.
#[cfg(target_os = "linux")]
fn members(cgroup: &Path) -> Vec<i32> {
    let Ok(text) = fs::read_to_string(cgroup.join("cgroup.procs")) else {
        return Vec::new();
    };

    text.lines().filter_map(|l| l.trim().parse::<i32>().ok()).collect()
}

/// Ask every session to end, politely.
///
/// SIGTERM by hand rather than `cgroup.kill`, which is SIGKILL only: a compositor wants the
/// chance to release the display before the kernel takes the device out from under it, and the
/// backend which stops services by cgroup is also the one which reboots this machine where the
/// backends which did not, did not.
///
/// This process and pid 1 are skipped explicitly as well as by cgroup, because the two
/// exclusions answer different questions - the cgroup check is about which tree, and these are
/// about not killing the thing doing the killing if the layout ever puts it in one.
#[cfg(target_os = "linux")]
pub fn terminate_sessions() {
    let self_pid = std::process::id() as i32;

    for cgroup in session_cgroups() {
        for pid in members(&cgroup) {
            if pid == self_pid || pid == 1 {
                continue;
            }
            unsafe {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}

/// Whether any session still has a process in it.
#[cfg(target_os = "linux")]
pub fn sessions_pending() -> bool {
    let self_pid = std::process::id() as i32;

    session_cgroups()
        .iter()
        .any(|cg| members(cg).iter().any(|&p| p != self_pid && p != 1))
}

/// The hammer, for anything that did not take the TERM.
///
/// One write kills the whole subtree at once, so nothing can fork while the list is being
/// walked - which is the failure mode of reading `cgroup.procs` and signalling it entry by
/// entry.
#[cfg(target_os = "linux")]
pub fn kill_sessions() {
    for cgroup in session_cgroups() {
        let _ = fs::write(cgroup.join("cgroup.kill"), "1");
    }
}

#[cfg(not(target_os = "linux"))]
pub fn terminate_sessions() {}

#[cfg(not(target_os = "linux"))]
pub fn sessions_pending() -> bool {
    false
}

#[cfg(not(target_os = "linux"))]
pub fn kill_sessions() {}
