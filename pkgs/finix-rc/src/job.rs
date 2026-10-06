//! One unit's whole life, as one process.
//!
//! The shape is deliberately the one the shell had, because the shape is why this backend is
//! fast. Each job is self-contained - wait on requires, latch, supervise - and they are all
//! launched at once, so a boot is a set of processes blocking on each other's latches rather
//! than anything central deciding what may start next. There is no scheduler here and no graph
//! in memory; the ordering is the waiting.
//!
//! That is also what makes `switch.activate` able to reach into a running generation without a
//! supervisor to ask: starting a unit after boot is running this same code again, with the same
//! argument, from a process that then exits.

use crate::latch::Latches;
use crate::manifest::{Kind, Manifest, Unit};
use crate::proc;
use crate::syslog;
use std::io;
use std::process::{Child, Command, ExitCode, Stdio};
use std::time::Duration;

/// Spawn with both streams captured and relayed to syslog.
///
/// Every command a job runs goes through this - the service, a oneshot, a readiness check -
/// because a unit which fails is exactly the one whose output is wanted, and a readiness command
/// that keeps giving up says why on stderr.
///
/// The relay threads own the pipes and end at EOF, which is the child exiting. Nothing has to be
/// joined, so a respawn loop can call this again on every pass without accumulating anything.
fn spawn_logged(cmd: &mut Command) -> io::Result<Child> {
    let mut child = cmd.stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;

    if let Some(stdout) = child.stdout.take() {
        syslog::relay(stdout, libc::LOG_INFO);
    }

    if let Some(stderr) = child.stderr.take() {
        syslog::relay(stderr, libc::LOG_ERR);
    }

    Ok(child)
}

/// The backoff `finix-wait` uses, for the same reason: these are all things which have just
/// been asked to happen, so the first retry is almost always the one that matters, and the
/// ceiling is what stops a genuinely absent latch from spinning a core.
const FIRST_DELAY: Duration = Duration::from_millis(1);
const MAX_DELAY: Duration = Duration::from_millis(20);

/// A service which stops on its own is restarted after this. A fixed backoff rather than
/// crash-loop detection - the same corner this backend cuts everywhere else - which is survivable
/// because a unit that cannot start logs on every attempt rather than silently vanishing.
const RESPAWN_BACKOFF: Duration = Duration::from_secs(1);

pub fn run(manifest: &Manifest, name: &str) -> ExitCode {
    let Some(unit) = manifest.units.get(name) else {
        eprintln!("finix-rc job: no unit named {name} in this generation");
        return ExitCode::from(1);
    };

    // tagged with the unit's name, which is what makes a log line attributable - the same thing
    // finit's `initctl` tag does. One job process serves one unit, so this is said once.
    syslog::open(name);

    let latches = Latches::new(&manifest.latch_dir);
    if let Err(e) = latches.ensure() {
        eprintln!("finix-rc job {name}: {}: {e}", manifest.latch_dir);
        return ExitCode::from(1);
    }

    // written before the wait, not after it: `switch.list` has to be able to say that a job for
    // this generation's definition of the unit has been launched, which is true from here. A
    // unit blocked on a dependency that never latches is still this generation's unit, and
    // reporting it as absent would make every switch try to start it again.
    if let Err(e) = latches.write_fingerprint(name, &unit.fingerprint) {
        eprintln!("finix-rc job {name}: writing fingerprint: {e}");
        return ExitCode::from(1);
    }

    wait_for_requires(&latches, unit);
    apply_environment(unit);

    match unit.kind {
        Kind::Anchor => {
            // a name to synchronise on, with nothing behind it.
            if let Err(e) = latches.stamp(name) {
                eprintln!("finix-rc job {name}: stamping latch: {e}");
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Kind::Oneshot => oneshot(&latches, manifest, name, unit),
        Kind::Service => service(&latches, manifest, name, unit),
    }
}

/// Block until every dependency has latched.
///
/// This used to be one `finix-wait path` process per edge. It is the highest-volume thing the
/// backend does - one per dependency per unit, which on this machine is a few hundred - and
/// since the job is now itself a program, the wait is a `stat` in the loop it was already going
/// to run. The polling behaviour is `finix-wait`'s unchanged, so a latch is still noticed within
/// about a millisecond of appearing.
fn wait_for_requires(latches: &Latches, unit: &Unit) {
    for dep in &unit.requires {
        let path = latches.ready(dep);
        let mut delay = FIRST_DELAY;
        while !Latches::exists(&path) {
            proc::sleep(delay);
            delay = (delay * 2).min(MAX_DELAY);
        }
    }
}

/// `export PATH=...:$PATH` and the unit's own environment, applied to this process so that
/// everything it spawns - the command, and a `waitFor.check` which may well need the same PATH -
/// inherits it.
///
/// `providers.services.units.<name>.environment` is part of the contract, and the shell version
/// of this backend did not read it for a long time: anything a unit said about its environment
/// was accepted and discarded. That included the HOME the contract defaults for a unit with a
/// user, which is the whole of why home-manager activation failed here, `cd $HOME` being its
/// first line.
///
/// Called before any thread is spawned, which is what makes `set_var` safe to use here.
fn apply_environment(unit: &Unit) {
    if !unit.path.is_empty() {
        let existing = std::env::var("PATH").unwrap_or_default();
        let prefix = unit.path.join(":");
        std::env::set_var(
            "PATH",
            if existing.is_empty() {
                prefix
            } else {
                format!("{prefix}:{existing}")
            },
        );
    }

    for (k, v) in &unit.environment {
        std::env::set_var(k, v);
    }
}

/// The command line, as the contract types it.
///
/// `providers.services.units.<name>.type.*.command` is "main program, path or command" - a
/// command *line*, which may carry arguments and which several units in the wild rely on being
/// shell. So it goes to a shell, exactly as it did when this was a shell script interpolating
/// it inline. That is one process, at unit start, which bash then execs out of for a simple
/// command; it is not on any hot path.
///
/// Making `command` an argv would remove even that, and would be a change to the contract every
/// backend reads - not something to do silently inside a port.
fn command_argv(manifest: &Manifest, unit: &Unit, command: &str) -> Command {
    let mut cmd;

    // `chpst -u`, from runit, rather than dropping privilege in this process.
    //
    // Not laziness: `chpst -u user` sets the user's *primary group* out of the passwd entry,
    // and their supplementary groups out of the group database. Reimplementing that means
    // reimplementing NSS lookup, and getting it subtly wrong means a unit running with more
    // group membership than it asked for - which is a privilege bug, in the one place the
    // contract makes an explicit promise about privilege.
    //
    // Worth knowing: `shutdown.nix` uses `setpriv --reuid` for the same job, which does *not*
    // set the primary group when no `--regid` is given. That difference is pre-existing and is
    // not something this port should quietly change on one side only.
    if let Some(user) = &unit.user {
        let spec = match &unit.group {
            Some(group) => format!("{user}:{group}"),
            None => user.clone(),
        };
        cmd = Command::new(&manifest.chpst);
        cmd.arg("-u").arg(spec).arg(&manifest.shell);
    } else {
        cmd = Command::new(&manifest.shell);
    }

    cmd.arg("-c").arg(command);
    cmd
}

/// Latched on success, and only on success.
///
/// The latch is what everything downstream waits for, so touching it unconditionally said "this
/// finished" where it meant "this stopped running". Nothing else observes a oneshot here, so a
/// failure became indistinguishable from a success on every path that mattered - and what that
/// produced was a compositor with no configuration: home-manager activation failed, its latch
/// was touched anyway, greetd started on the strength of it, and niri went looking for a config
/// nothing had linked yet.
///
/// A failed oneshot holds its dependents. That is the more useful failure: a boot which stops at
/// the unit that broke, rather than one which carries on and shows you the consequence three
/// steps later.
///
/// No new session, which matches what the shell did: a oneshot is not supervised and nothing
/// signals it by group, so there is nothing for one to buy.
fn oneshot(latches: &Latches, manifest: &Manifest, name: &str, unit: &Unit) -> ExitCode {
    let Some(command) = &unit.command else {
        eprintln!("finix-rc job {name}: oneshot with no command");
        return ExitCode::from(1);
    };

    let status = spawn_logged(&mut command_argv(manifest, unit, command))
        .and_then(|mut child| child.wait());

    match status {
        Ok(status) if status.success() => {
            if let Err(e) = latches.stamp(name) {
                eprintln!("finix-rc job {name}: stamping latch: {e}");
                return ExitCode::from(1);
            }
            ExitCode::SUCCESS
        }
        Ok(status) => {
            eprintln!(
                "{name}: exited {}, so {} is not being touched - anything requiring it waits",
                status.code().unwrap_or(-1),
                latches.ready(name).display()
            );
            ExitCode::from(1)
        }
        Err(e) => {
            eprintln!("{name}: could not be started: {e} - anything requiring it waits");
            ExitCode::from(1)
        }
    }
}

fn service(latches: &Latches, manifest: &Manifest, name: &str, unit: &Unit) -> ExitCode {
    match &unit.readiness_command {
        // Nothing to latch from once the daemon is running, so the wait runs alongside it and
        // latches when whatever it is waiting for is live - the same shape as runit's, and for
        // the same reason: nothing here observes a daemon's readiness natively either.
        //
        // Only on success, for the reason the oneshot above has the same condition: a readiness
        // command which gives up has established that the daemon is *not* ready, and latching on
        // the way out of it would say the opposite.
        //
        // A thread rather than the background job this was, so that a readiness command which
        // never returns is one blocked thread rather than an orphan nothing is left to reap.
        Some(readiness) => {
            let readiness = readiness.clone();
            let shell = manifest.shell.clone();
            let ready_path = latches.ready(name).to_path_buf();
            let latch_dir = manifest.latch_dir.clone();
            let unit_name = name.to_string();

            std::thread::spawn(move || {
                let ok = spawn_logged(Command::new(&shell).arg("-c").arg(&readiness))
                    .and_then(|mut child| child.wait())
                    .map(|s| s.success())
                    .unwrap_or(false);

                if ok {
                    if let Err(e) = Latches::new(&latch_dir).stamp(&unit_name) {
                        eprintln!("finix-rc job {unit_name}: stamping latch: {e}");
                    }
                } else {
                    eprintln!(
                        "{unit_name}: readiness gave up, so {} is not being touched",
                        ready_path.display()
                    );
                }
            });
        }

        // `fork` readiness: up the moment it is running, which is what "supervised" means here.
        // `notify` and `s6` never reach this - the contract refuses them against this backend.
        None => {
            if let Err(e) = latches.stamp(name) {
                eprintln!("finix-rc job {name}: stamping latch: {e}");
            }
        }
    }

    supervise(latches, manifest, name, unit)
}

/// The respawn loop, since nothing here supervises a service but this.
///
/// The stop file is what ends it, and it is checked *after* the child has been reaped rather
/// than before the next start: `rc.shutdown` and `switch.deactivate` both write it before they
/// signal, precisely so that the TERM they send does not get answered by a fresh start.
fn supervise(latches: &Latches, manifest: &Manifest, name: &str, unit: &Unit) -> ExitCode {
    let Some(command) = &unit.command else {
        eprintln!("finix-rc job {name}: service with no command");
        return ExitCode::from(1);
    };

    let stop = latches.stop(name);
    let pidfile = latches.pid(name);

    loop {
        let mut cmd = command_argv(manifest, unit, command);
        let child = spawn_logged(proc::in_new_session(&mut cmd));

        match child {
            Ok(mut child) => {
                // the pid is also the process group id, the child being a session leader - which
                // is what lets everything that stops a unit signal the group and reach whatever
                // the service forked.
                let _ = std::fs::write(&pidfile, child.id().to_string());
                let _ = child.wait();
                let _ = std::fs::remove_file(&pidfile);
            }
            Err(e) => {
                eprintln!("{name}: could not be started: {e}");
            }
        }

        if Latches::exists(&stop) {
            return ExitCode::SUCCESS;
        }

        proc::sleep(RESPAWN_BACKOFF);
    }
}
