use crate::util::{cmd::CmdError, mountinfo::MountinfoError};
use snafu::Snafu;
use std::path::PathBuf;

/// Anything that goes wrong once we start touching the boot filesystem.
#[derive(Debug, Snafu)]
#[snafu(visibility(pub(crate)))]
pub(crate) enum InstallError {
    /// A file or directory could not be read.
    #[snafu(display("could not read {}", path.display()))]
    Read {
        source: std::io::Error,
        path: PathBuf,
    },
    /// A file could not be written.
    #[snafu(display("could not write {}", path.display()))]
    Write {
        source: std::io::Error,
        path: PathBuf,
    },
    /// A file could not be copied onto the boot filesystem.
    #[snafu(display("could not copy {} to {}", from.display(), to.display()))]
    Copy {
        source: std::io::Error,
        from: PathBuf,
        to: PathBuf,
    },
    /// A directory could not be created.
    #[snafu(display("could not create {}", path.display()))]
    CreateDir {
        source: std::io::Error,
        path: PathBuf,
    },
    /// A stale file or the xen directory could not be removed.
    #[snafu(display("could not remove {}", path.display()))]
    Remove {
        source: std::io::Error,
        path: PathBuf,
    },
    /// A helper binary could not be run, or ran and failed.
    #[snafu(display("{source}"), context(false))]
    Command { source: CmdError },
    /// `limine bios-install` failed.
    #[snafu(display(
        "failed to deploy the BIOS stage 1 bootloader; you might want to try enabling programs.limine.force"
    ))]
    BiosInstall { source: CmdError },
    /// A generation's `boot.json` is missing or malformed.
    #[snafu(display("could not parse {}", path.display()))]
    ParseBootSpec {
        source: serde_json::Error,
        path: PathBuf,
    },
    /// The system profile has no generations, so there is nothing to boot.
    #[snafu(display("the system profile has no generations"))]
    NoGenerations,
    /// Secure boot was requested with keys that have to already exist.
    #[snafu(display(
        "there are no sbctl secure boot keys present; generate some, or enable programs.limine.secureBoot.autoGenerateKeys"
    ))]
    NoSecureBootKeys,
    /// The ESP could not be traced back to a device.
    #[snafu(display("{source}"), context(false))]
    Mountinfo { source: MountinfoError },
    /// sysfs does not say which disk and partition the ESP device is.
    #[snafu(display("could not work out which partition {} is", path.display()))]
    UnknownPartition { path: PathBuf },
    /// The firmware variables could not be read or written.
    #[snafu(display("could not update the firmware boot entries"))]
    Nvram { source: efivar::Error },
    /// The disk holding the ESP has no readable partition table.
    #[snafu(display("could not read the partition table of {}", path.display()))]
    PartitionTable {
        source: gpt::GptError,
        path: PathBuf,
    },
    /// The ESP is not in the partition table of the disk it sits on.
    #[snafu(display("{} has no partition {number}", path.display()))]
    NoSuchPartition { path: PathBuf, number: u32 },
    /// A Xen EFI entry was asked for without the binary to boot.
    #[snafu(display("generation {generation} has a Xen bootspec with no efiPath"))]
    XenWithoutEfiPath { generation: u32 },
    /// The boot filesystem could not be flushed.
    #[snafu(display("could not sync {}", path.display()))]
    SyncFs {
        source: rustix::io::Errno,
        path: PathBuf,
    },
}
