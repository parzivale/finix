//! `/run/providers-services`, which is this backend's entire runtime state.
//!
//! Deliberately unchanged by the port. There is no control socket here and nothing to ask, so
//! four files per unit are what a thin backend knows about itself, and they are read by things
//! outside this binary: `switch` compares `.fingerprint` across generations, `ctl status`
//! prints a state derived from all four, and the boot measurement in the host configuration is
//! read straight out of `.ready`. Changing the layout during a rewrite would have made every
//! one of those a second thing to debug if the rewrite went wrong.
//!
//!   `<unit>.ready`        the latch. Its existence is the readiness signal every dependent
//!                         waits on; its contents are the moment it was written.
//!   `<unit>.pid`          the supervised child's pid, present only while it is alive.
//!   `<unit>.stop`         "do not respawn" - written before the signal, removed before a
//!                         fresh start. See `job::supervise`.
//!   `<unit>.fingerprint`  which generation's definition this job was launched from.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub struct Latches {
    dir: PathBuf,
}

impl Latches {
    pub fn new(dir: &str) -> Self {
        Self {
            dir: PathBuf::from(dir),
        }
    }


    /// every subcommand which writes calls this first. rc.init and the job both did, in the
    /// shell, for the reason that still holds: a job started by `switch.activate` long after
    /// boot has no guarantee about who ran before it.
    pub fn ensure(&self) -> io::Result<()> {
        fs::create_dir_all(&self.dir)
    }

    pub fn ready(&self, unit: &str) -> PathBuf {
        self.dir.join(format!("{unit}.ready"))
    }

    pub fn pid(&self, unit: &str) -> PathBuf {
        self.dir.join(format!("{unit}.pid"))
    }

    pub fn stop(&self, unit: &str) -> PathBuf {
        self.dir.join(format!("{unit}.stop"))
    }

    pub fn fingerprint(&self, unit: &str) -> PathBuf {
        self.dir.join(format!("{unit}.fingerprint"))
    }

    /// The latch carries the moment it was created, because nothing reads its contents and
    /// something has to be able to see inside a boot.
    ///
    /// A waiter tests for existence and never looks further, so the file was empty at first and
    /// the only record of when a unit became ready was its mtime. That is not a measurement on
    /// this hardware: every mtime lands on an exact integer second, so a whole boot reads as
    /// three or four one-second steps and the structure inside them is invisible. Worse, the
    /// realtime clock is set partway through userspace - by the RTC driver, once it probes - so
    /// latches written before that point carry a time near zero and cannot be compared with the
    /// ones after it at all.
    ///
    /// /proc/uptime is monotonic, starts when the kernel did, and is good to 10ms. Read the
    /// latch directory after a boot and every unit says when it was ready, in one timebase,
    /// with no clock jump in the middle of it.
    pub fn stamp(&self, unit: &str) -> io::Result<()> {
        let uptime = fs::read_to_string("/proc/uptime").unwrap_or_default();
        let secs = uptime.split_whitespace().next().unwrap_or("0").to_string();
        fs::write(self.ready(unit), secs)
    }

    pub fn write_fingerprint(&self, unit: &str, fingerprint: &str) -> io::Result<()> {
        fs::write(self.fingerprint(unit), fingerprint)
    }

    /// `[ -e ]`, which follows symlinks - the same test `finix-wait` makes, and it has to be
    /// the same one: a dangling latch is not something a dependent can use.
    pub fn exists(path: &Path) -> bool {
        path.metadata().is_ok()
    }

    /// Every unit which has a `.pid` right now, by name.
    ///
    /// The shell globbed `*.pid` and stripped the suffix. The glob is the part worth replacing
    /// rather than reproducing: an unmatched glob in POSIX sh stays literal, which is why the
    /// script it came from had to keep asking whether `$1` was a real file, and that question
    /// is what destroyed the shutdown argument. A directory read that finds nothing returns an
    /// empty vector and there is nothing to ask.
    pub fn with_suffix(&self, suffix: &str) -> Vec<String> {
        let Ok(entries) = fs::read_dir(&self.dir) else {
            return Vec::new();
        };

        let mut names: Vec<String> = entries
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().into_string().ok()?;
                name.strip_suffix(suffix).map(|s| s.to_string())
            })
            .collect();

        names.sort();
        names
    }

    pub fn read_pid(&self, unit: &str) -> Option<i32> {
        fs::read_to_string(self.pid(unit))
            .ok()?
            .trim()
            .parse::<i32>()
            .ok()
    }
}
