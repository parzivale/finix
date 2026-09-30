//! The preamble every finix boot runs before its service manager.
//!
//! One binary is `boot.init` on both paths. On the finit path stage 1 has already built `/` and
//! mounted the store, so most of what follows is a no-op and the useful part is activation. With
//! no initrd the kernel has mounted `/` and exec'd this, and that is the whole of what has
//! happened: nothing else is mounted, `/etc` does not exist yet, and the configuration the
//! service manager is about to read is one of the things activation is going to put there.
//!
//! It works out its situation from what it finds rather than from flags, so the same binary
//! serves both.
//!
//! This is PID 1. The kernel treats its death as a panic, so there is no error path that returns:
//! every failure either continues deliberately or ends in `rescue`, which execs a shell from the
//! store when the store is reachable and otherwise says so and sleeps. Nothing here spawns except
//! `activate`, and that is waited on.

use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

use rustix::mount::{mount, MountFlags};
use serde::Deserialize;

/// What the configuration tells this binary to do, emitted into the toplevel beside `activate`.
///
/// Deliberately not `boot.json`: that name is taken by the bootspec, which bootloader installers
/// parse and which has no business carrying our fields.
///
/// Fields are optional wherever a later phase adds one, so a binary from this generation keeps
/// working against a file from the next and the other way round.
#[derive(Deserialize)]
struct Config {
    #[allow(dead_code)]
    version: u32,
    /// The service manager and its arguments. The last thing this process does.
    exec: Vec<String>,
}

/// A message on the console, which is the only place anything can be said this early.
macro_rules! say {
    ($($arg:tt)*) => {{
        let mut err = std::io::stderr();
        let _ = writeln!(err, "finix-init: {}", format_args!($($arg)*));
        let _ = err.flush();
    }};
}

fn main() {
    // a panic here would otherwise be a kernel panic with a worse message attached
    std::panic::set_hook(Box::new(|info| {
        say!("panicked: {info}");
        say!("this is PID 1, so there is nowhere to return to");
    }));

    // step 1: /proc, because the next thing this does is read from it
    //
    // With an initrd this has been mounted since stage 1 and survived the switch_root. With none,
    // nothing has mounted anything, and the failure that produces is misleading: reading
    // /proc/cmdline gets ENOENT, which looks like a kernel that was passed no command line
    // rather than a /proc that is not there.
    ensure_mount("proc", "/proc", "proc", MountFlags::NOSUID | MountFlags::NODEV | MountFlags::NOEXEC);

    let system = match find_system() {
        Some(s) => s,
        None => rescue("cannot tell which system to activate: no finix_system= or init= on the kernel command line"),
    };
    say!("system is {}", system.display());

    // step 4: the rest of the virtual filesystems.
    //
    // /dev before anything names a device node, which activation does. CONFIG_DEVTMPFS_MOUNT
    // sounds like it covers this and does not: the kernel mounts devtmpfs for a root it mounted
    // itself, and only after `/` is in place - not for a root handed over by an initramfs.
    ensure_mount("sys", "/sys", "sysfs", MountFlags::NOSUID | MountFlags::NODEV | MountFlags::NOEXEC);
    ensure_mount("devtmpfs", "/dev", "devtmpfs", MountFlags::NOSUID);
    ensure_mount("tmpfs", "/run", "tmpfs", MountFlags::NOSUID | MountFlags::NODEV);

    let config = match read_config(&system) {
        Ok(c) => c,
        Err(e) => rescue(&format!("{e}")),
    };

    // step 6: activation, and its status.
    //
    // The service manager's own configuration is in /etc, and /etc is what this puts there, so
    // there is no ordering in which the manager could do it for itself. Running it and not
    // looking at the result was how a failure here turned into the manager complaining about a
    // missing /etc/fstab three steps later.
    activate(&system);

    // step 8: the service manager, exec'd rather than spawned, because PID 1 is what it has to be
    exec_manager(&config, &system)
}

/// Mount `target` unless something is already there.
///
/// Idempotent because the finit path arrives with all of these mounted and the no-initrd path
/// with none of them, and asking which is which is more fragile than trying.
fn ensure_mount(source: &str, target: &str, fstype: &str, flags: MountFlags) {
    if is_mounted(target) {
        return;
    }

    // an initramfs holds what was put in it and nothing else, so the mount point may not exist -
    // and mount(2) on a missing path fails with the same ENOENT as a missing device
    if let Err(e) = fs::create_dir_all(target) {
        say!("cannot create {target}: {e}");
        return;
    }

    if let Err(e) = mount(source, target, fstype, flags, "") {
        say!("cannot mount {fstype} on {target}: {e}");
    }
}

/// Whether anything is mounted at `target`, by asking whether it and its parent are on the same
/// device. Cheaper than parsing /proc/mounts, and works before /proc is mounted, which is the
/// case this is first used in.
fn is_mounted(target: &str) -> bool {
    let path = Path::new(target);
    let Ok(here) = fs::metadata(path) else {
        return false;
    };
    let Some(parent) = path.parent() else {
        return false;
    };
    let Ok(up) = fs::metadata(parent) else {
        return false;
    };

    use std::os::unix::fs::MetadataExt;
    here.dev() != up.dev()
}

/// The toplevel whose configuration this boot is.
///
/// `finix_system=` is the direct statement of it. `init=` is the fallback, and is what
/// finix-activate used: the kernel leaves it on the command line even when it exec'd something
/// else, so the closure can be recovered from the directory holding the init that was named.
fn find_system() -> Option<PathBuf> {
    let cmdline = fs::read_to_string("/proc/cmdline").ok()?;

    let mut from_init = None;
    for param in cmdline.split_whitespace() {
        if let Some(v) = param.strip_prefix("finix_system=") {
            return Some(PathBuf::from(v));
        }
        if let Some(v) = param.strip_prefix("init=") {
            from_init = Path::new(v).parent().map(Path::to_path_buf);
        }
    }
    from_init
}

fn read_config(system: &Path) -> Result<Config, String> {
    let path = system.join("finix-init.json");
    let text = fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {}: {e} - is the store mounted?", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("cannot parse {}: {e}", path.display()))
}

/// Run the closure's `activate`, wait for it, and place the two symlinks naming this generation.
fn activate(system: &Path) {
    let script = system.join("activate");
    match Command::new(&script).status() {
        Ok(status) if status.success() => {}
        Ok(status) => {
            // loud, and not fatal on its own: an activation script reports failure if any of its
            // snippets failed, and carries on past the ones that did. Some of what it does is not
            // needed to reach a service manager, and a machine that boots far enough to be logged
            // into is worth more than one that stops here.
            say!("activation reported {status} - the system may be incomplete");
        }
        Err(e) => rescue(&format!("cannot run {}: {e}", script.display())),
    }

    // both written through a temporary and renamed, so neither is ever a dangling or half-made
    // link that something reads between the unlink and the symlink
    link_atomically(system, "/run/booted-system");
    link_atomically(system, "/run/current-system");
}

fn link_atomically(target: &Path, link: &str) {
    let tmp = format!("{link}.finix-init");
    let _ = fs::remove_file(&tmp);
    if let Err(e) = std::os::unix::fs::symlink(target, &tmp) {
        say!("cannot create {tmp}: {e}");
        return;
    }
    if let Err(e) = fs::rename(&tmp, link) {
        say!("cannot move {tmp} to {link}: {e}");
    }
}

fn exec_manager(config: &Config, system: &Path) -> ! {
    let Some((program, args)) = config.exec.split_first() else {
        rescue("finix-init.json names no exec, so there is no service manager to hand over to")
    };

    // anything the kernel passed after the init's own path. A service manager which takes
    // arguments from the command line gets them; one which does not is handed nothing extra.
    let passed: Vec<OsString> = std::env::args_os().skip(1).collect();

    say!("exec {program}");
    let err = Command::new(program).args(args).args(&passed).exec();

    // exec only returns on failure
    say!("cannot exec {program}: {err}");
    rescue(&format!("the service manager named by {}/finix-init.json did not start", system.display()))
}

/// The end of every path that cannot continue.
///
/// A shell if the store is reachable, because by then it usually is and a shell with the whole
/// closure behind it is the difference between diagnosing this on the machine and rebooting into
/// the same failure. Sleeping otherwise: returning from PID 1 is a kernel panic, and a panic
/// scrolls the reason off the screen.
fn rescue(why: &str) -> ! {
    say!("{why}");

    for shell in ["/run/current-system/sw/bin/bash", "/bin/sh"] {
        if Path::new(shell).exists() {
            say!("dropping to {shell}");
            let _ = Command::new(shell).arg("-i").exec();
        }
    }

    say!("no shell is reachable, so there is nothing further to try");
    say!("the store holds {} entries", count_store());
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}

/// Whether the store is there at all, which is the question behind most failures this early.
/// Counted rather than tested for existence: the mount points are created before anything is
/// mounted onto them, so the directory is there either way.
fn count_store() -> usize {
    fs::read_dir("/nix/store").map(|d| d.count()).unwrap_or(0)
}

