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

/// A message on the console, which is the only place anything can be said this early.
///
/// Defined before everything that uses it: `macro_rules!` is textual, so a macro used above its
/// definition is simply not in scope, and the error says so in terms of the use rather than the
/// order.
macro_rules! say {
    ($($arg:tt)*) => {{
        let mut err = std::io::stderr();
        let _ = writeln!(err, "finix-init: {}", format_args!($($arg)*));
        let _ = err.flush();
    }};
}



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

    /// Filesystems to mount before activation, shallowest first.
    #[serde(default)]
    mounts: Vec<Mount>,

    /// Steps to take before the exec. Absent in a file from a configuration that needed none.
    #[serde(default)]
    pre: Vec<PreOp>,
}

/// A filesystem the configuration wants mounted before the service manager starts.
///
/// `neededForBoot`, in other words - which used to mean "a thing only an initrd can do", and was
/// refused outright on a machine with none. It is this binary's job now, which is the same job
/// stage one had and the reason stage one existed.
#[derive(Deserialize)]
struct Mount {
    device: String,
    #[serde(rename = "mountPoint")]
    mount_point: PathBuf,
    #[serde(rename = "fsType")]
    fs_type: String,
    #[serde(default)]
    options: Vec<String>,
}

/// Mount them shallowest first.
///
/// Ordered by the configuration rather than sorted here, because the ordering that matters is not
/// alphabetical: a path cannot be mounted over a parent which is not there yet, and the Nix side
/// already knows the depth of each.
fn mount_all(mounts: &[Mount]) {
    for m in mounts {
        if is_mounted_path(&m.mount_point) {
            continue;
        }

        if let Err(e) = fs::create_dir_all(&m.mount_point) {
            say!("cannot create {}: {e}", m.mount_point.display());
            continue;
        }

        // the options as one comma-joined string, which is what mount(2) takes as its data
        // argument - the same thing `-o` is, rather than anything mount(8) invented
        let data = m.options.join(",");

        if let Err(e) = mount(
            m.device.as_str(),
            &m.mount_point,
            m.fs_type.as_str(),
            MountFlags::empty(),
            data.as_str(),
        ) {
            // not fatal here: what is fatal is the store being absent, and that is caught where
            // the configuration is read. A machine missing /persistent has a chance of saying so.
            say!(
                "cannot mount {} on {} ({}): {e}",
                m.device,
                m.mount_point.display(),
                m.fs_type
            );
        }
    }
}

fn is_mounted_path(target: &Path) -> bool {
    is_mounted(&target.to_string_lossy())
}

/// A step a backend needs before its first instruction, named as data rather than written as a
/// shell script per backend.
///
/// These exist because two backends want the same thing: the generation's own view of what is
/// running, copied somewhere writable, because the store is not. dinit's fingerprints and
/// openrc's unit directory are the same operation with different paths, and each had its own
/// three lines of `rm -rf`, `cp -rL`, `chmod -R u+w`.
#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum PreOp {
    /// Replace `to` with a writable copy of `from`, following symlinks.
    ///
    /// Dereferencing is the point: `from` is in the store, so a plain copy would give a tree of
    /// links back into it and `writable` would be a lie.
    CopyTree {
        from: PathBuf,
        to: PathBuf,
        #[serde(default)]
        writable: bool,
    },
    Mkdir {
        path: PathBuf,
    },
    Symlink {
        from: PathBuf,
        to: PathBuf,
    },
    /// A named pipe, which is why some of these trees cannot simply be store paths: a fifo is
    /// not something a derivation can contain.
    Mkfifo {
        path: PathBuf,
        #[serde(default = "fifo_mode")]
        mode: u32,
    },
}

fn fifo_mode() -> u32 {
    0o600
}

fn run_pre(ops: &[PreOp]) {
    for op in ops {
        let result = match op {
            PreOp::CopyTree { from, to, writable } => copy_tree(from, to, *writable),
            PreOp::Mkdir { path } => fs::create_dir_all(path).map_err(|e| e.to_string()),
            PreOp::Symlink { from, to } => {
                let _ = fs::remove_file(to);
                std::os::unix::fs::symlink(from, to).map_err(|e| e.to_string())
            }
            PreOp::Mkfifo { path, mode } => {
                let _ = fs::remove_file(path);
                rustix::fs::mknodat(
                    rustix::fs::CWD,
                    path,
                    rustix::fs::FileType::Fifo,
                    rustix::fs::Mode::from_bits_truncate(*mode),
                    0,
                )
                .map_err(|e| e.to_string())
            }
        };

        // loud and not fatal: these prepare a backend's own state, and a backend that then cannot
        // start says so far more precisely than this can guess at here
        if let Err(e) = result {
            say!("pre step failed: {e}");
        }
    }
}

/// `rm -rf to && cp -rL from to && chmod -R u+w to`, which is what this replaces.
fn copy_tree(from: &Path, to: &Path, writable: bool) -> Result<(), String> {
    if to.exists() {
        let meta = fs::symlink_metadata(to).map_err(|e| e.to_string())?;
        if meta.is_dir() {
            fs::remove_dir_all(to).map_err(|e| format!("cannot replace {}: {e}", to.display()))?;
        } else {
            fs::remove_file(to).map_err(|e| format!("cannot replace {}: {e}", to.display()))?;
        }
    }
    copy_into(from, to, writable)
}

fn copy_into(from: &Path, to: &Path, writable: bool) -> Result<(), String> {
    // `metadata` rather than `symlink_metadata`, so a symlink is copied as what it points at
    let meta = fs::metadata(from).map_err(|e| format!("cannot read {}: {e}", from.display()))?;

    if meta.is_dir() {
        fs::create_dir_all(to).map_err(|e| format!("cannot create {}: {e}", to.display()))?;
        for entry in fs::read_dir(from).map_err(|e| format!("cannot list {}: {e}", from.display()))? {
            let entry = entry.map_err(|e| e.to_string())?;
            copy_into(&entry.path(), &to.join(entry.file_name()), writable)?;
        }
        if writable {
            make_writable(to, &meta)?;
        }
        return Ok(());
    }

    fs::copy(from, to).map_err(|e| format!("cannot copy {} to {}: {e}", from.display(), to.display()))?;
    if writable {
        make_writable(to, &meta)?;
    }
    Ok(())
}

fn make_writable(path: &Path, from: &fs::Metadata) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = from.permissions();
    perms.set_mode(perms.mode() | 0o200);
    fs::set_permissions(path, perms).map_err(|e| format!("cannot make {} writable: {e}", path.display()))
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

    // step 5: the filesystems the configuration says have to be there first
    mount_all(&config.mounts);

    // step 6: activation, and its status.
    //
    // The service manager's own configuration is in /etc, and /etc is what this puts there, so
    // there is no ordering in which the manager could do it for itself. Running it and not
    // looking at the result was how a failure here turned into the manager complaining about a
    // missing /etc/fstab three steps later.
    activate(&system);

    // step 7: whatever the backend needs in place first
    run_pre(&config.pre);

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

