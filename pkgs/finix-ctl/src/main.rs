//! `initctl`: one front-end for inspecting and controlling units, whichever init is underneath.
//!
//! The primitives already existed and were only reachable one backend at a time. Every
//! implementation supplies `switch.list`, `switch.activate` and `switch.deactivate` - that is
//! what reconciles a generation - and `shutdownCommands`, which is how the machine halts. What
//! was missing was a way to ask for one unit by name, and a way to reach a *user's* supervisor at
//! all: its socket path was a convention inside the dinit module and nothing surfaced it.
//!
//! So the shape of the problem was a tool per backend per tree - finit's `initctl` on PATH
//! talking to an init which is not running, `dinitctl` not installed despite dinit supervising
//! the whole session. One name, resolved to the backend this machine actually runs.
//!
//! # Why this is a program
//!
//! Not for speed: it is typed by a person, and the forks it used to cost were invisible. It is
//! because the two bugs this file's shell ancestor recorded in its own comments were both
//! argument handling, and both were silent:
//!
//!   - the refusal in `resolve` was computed inside `$(...)`, so its `exit` ended the subshell
//!     and `initctl` went on to report success. A caller testing the exit status - the only
//!     thing a script can do - was told the unit existed.
//!   - `--user` was recognised immediately after the command and ignored everywhere else, so
//!     `initctl status nix-daemon --user bella` answered about the system unit as though the flag
//!     had not been given.
//!
//! Neither had a test. Both do now, written against the shell before this existed, so that this
//! had something to agree with other than itself: `tests/providers/core/initctl.nix` and
//! `tests/providers/initctl-trees.nix`.
//!
//! The third thing it buys is that `resolve` became testable at all - see resolve.rs, which has
//! the cases a VM test would need a whole machine to reach.

mod manifest;
mod resolve;

use manifest::Manifest;
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};

fn usage() -> ExitCode {
    eprintln!(
        "usage: initctl <command> [unit] [--user <name> | --system]

  list                 every unit, in every tree
  status <unit>        one unit's state
  start|stop <unit>    ...
  restart <unit>       stop then start, unless the backend has its own
  reboot|poweroff|halt the machine

A unit is named on its own and found in your own tree first, then the system's.
`--system` forces the system tree for a name that is in both; `--user` names
another user's."
    );
    ExitCode::from(2)
}

/// `id -un`, which is what decides whether an unqualified name means the caller's own tree.
///
/// Through `getpwuid`, so it is an NSS lookup and means the same thing the shell's `id -un` did -
/// which is why this crate is dynamically linked while the rest of finix's binaries are not. See
/// default.nix.
fn whoami() -> String {
    unsafe {
        let passwd = libc::getpwuid(libc::geteuid());
        if passwd.is_null() {
            return String::new();
        }

        std::ffi::CStr::from_ptr((*passwd).pw_name)
            .to_string_lossy()
            .into_owned()
    }
}

/// Run a command line and collect its stdout. Used for the `status` commands, which are specified
/// to answer `name<TAB>state` and are the only things here whose output this program reads rather
/// than passes through.
fn capture(shell: &str, command: &str) -> Option<String> {
    let out = Command::new(shell).arg("-c").arg(command).output().ok()?;
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn states(shell: &str, command: &str) -> Vec<(String, String)> {
    capture(shell, command)
        .unwrap_or_default()
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .map(|(unit, state)| (unit.to_string(), state.to_string()))
        .collect()
}

/// `printf '%s\n' "$unit" | <command>`: both `switch.activate` and `switch.deactivate` take unit
/// names on stdin, one per line, because that is the interface `switch-to-configuration` uses and
/// this is just another caller of it.
fn feed(shell: &str, command: &str, unit: &str) -> std::io::Result<std::process::ExitStatus> {
    let mut child = Command::new(shell)
        .arg("-c")
        .arg(command)
        .stdin(Stdio::piped())
        .spawn()?;

    if let Some(stdin) = child.stdin.as_mut() {
        writeln!(stdin, "{unit}")?;
    }
    drop(child.stdin.take());

    child.wait()
}

/// A user's supervisor takes a subcommand and a name as arguments, so its command line is split
/// into an argv and the two are appended - exactly what the shell did with an unquoted array
/// expansion, written out so that it is a decision rather than a side effect of word splitting.
fn user_ctl(ctl: &str, command: &str, unit: &str) -> std::io::Result<std::process::ExitStatus> {
    let mut argv = ctl.split_whitespace();

    let Some(program) = argv.next() else {
        return Err(std::io::Error::other("empty user ctl command"));
    };

    Command::new(program)
        .args(argv)
        .arg(command)
        .arg(unit)
        .status()
}

/// The machine goes down through whichever command the backend named, and this process is
/// replaced rather than waiting on it - `exec` in the shell, and for the same reason: there is
/// nothing left for this to do afterwards and on several backends the command never returns.
fn shutdown(shell: &str, command: Option<&String>) -> ExitCode {
    let Some(command) = command else {
        eprintln!("initctl: this backend supplies no command for that");
        return ExitCode::from(1);
    };

    let error = Command::new(shell).arg("-c").arg(command).exec();
    eprintln!("initctl: {command}: {error}");
    ExitCode::from(1)
}

struct Args {
    command: String,
    unit: Option<String>,
    tree: Option<String>,
}

/// Arguments in any order.
///
/// The shell version only recognised `--user` immediately after the command and silently ignored
/// it anywhere else, which is a worse answer than refusing it: the flag appearing to be accepted
/// is what made the bug invisible. Here there is one loop and position carries no meaning.
fn parse(argv: &[String]) -> Option<Args> {
    let mut command = None;
    let mut unit = None;
    let mut tree = None;

    let mut rest = argv.iter();

    while let Some(arg) = rest.next() {
        match arg.as_str() {
            "--user" => tree = Some(rest.next()?.clone()),
            "--system" => tree = Some("system".to_string()),
            _ if arg.starts_with('-') => return None,
            _ if command.is_none() => command = Some(arg.clone()),
            _ if unit.is_none() => unit = Some(arg.clone()),
            _ => return None,
        }
    }

    Some(Args {
        command: command?,
        unit,
        tree,
    })
}

fn list(manifest: &Manifest) -> ExitCode {
    println!("{:<10} {:<28} {}", "TREE", "UNIT", "STATE");

    for (unit, state) in states(&manifest.shell, &manifest.system.status) {
        println!("{:<10} {:<28} {}", "system", unit, state);
    }

    for (user, tree) in &manifest.users {
        for (unit, state) in states(&manifest.shell, &tree.status) {
            println!("{user:<10} {unit:<28} {state}");
        }
    }

    ExitCode::SUCCESS
}

fn act(manifest: &Manifest, args: &Args) -> ExitCode {
    let Some(unit) = &args.unit else {
        return usage();
    };

    let tree = match resolve::resolve(&manifest.index, unit, args.tree.as_deref(), &whoami()) {
        Ok(tree) => tree,
        Err(e) => {
            // on stderr and with a failing status, which is the bug this replaces: the shell's
            // refusal happened inside a command substitution and never reached the exit code.
            eprintln!("{e}");
            return ExitCode::from(1);
        }
    };

    if tree == "system" {
        let system = &manifest.system;

        let status = match args.command.as_str() {
            "status" => {
                for (name, state) in states(&manifest.shell, &system.status) {
                    if name == *unit {
                        println!("{state}");
                    }
                }
                return ExitCode::SUCCESS;
            }
            "start" => feed(&manifest.shell, &system.activate, unit),
            "stop" => feed(&manifest.shell, &system.deactivate, unit),
            "restart" => feed(&manifest.shell, &system.deactivate, unit)
                .and_then(|_| feed(&manifest.shell, &system.activate, unit)),
            _ => return usage(),
        };

        return match status {
            Ok(status) if status.success() => ExitCode::SUCCESS,
            Ok(_) => ExitCode::from(1),
            Err(e) => {
                eprintln!("initctl: {unit}: {e}");
                ExitCode::from(1)
            }
        };
    }

    let Some(user) = manifest.users.get(&tree) else {
        eprintln!("initctl: no supervisor for '{tree}'");
        return ExitCode::from(1);
    };

    match user_ctl(&user.ctl, &args.command, unit) {
        Ok(status) if status.success() => ExitCode::SUCCESS,
        Ok(_) => ExitCode::from(1),
        Err(e) => {
            eprintln!("initctl: {unit}: {e}");
            ExitCode::from(1)
        }
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();

    // the manifest is first and is not something a person types: the wrapper in ctl.nix supplies
    // it, the same way every other finix binary is handed what Nix resolved.
    let [manifest_path, rest @ ..] = argv.as_slice() else {
        return usage();
    };

    let manifest = match Manifest::load(manifest_path) {
        Ok(manifest) => manifest,
        Err(e) => {
            eprintln!("initctl: {e}");
            return ExitCode::from(1);
        }
    };

    let Some(args) = parse(rest) else {
        return usage();
    };

    match args.command.as_str() {
        "list" => list(&manifest),
        "status" | "start" | "stop" | "restart" => act(&manifest, &args),
        "reboot" => shutdown(&manifest.shell, manifest.shutdown.reboot.as_ref()),
        "poweroff" => shutdown(&manifest.shell, manifest.shutdown.poweroff.as_ref()),
        "halt" => shutdown(&manifest.shell, manifest.shutdown.halt.as_ref()),
        _ => usage(),
    }
}
