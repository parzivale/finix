use super::Raw;
use crate::config::{
    Arch, BiosConfig, Stage1,
    error::{BiosUnsupportedArchSnafu, ConfigError},
};
use snafu::ensure;
use std::path::PathBuf;

/// The wire encoding of "install stage 2, but write stage 1 nowhere".
const NODEV: &str = "nodev";

/// `None` when `biosSupport` is off.
pub(super) fn resolve(r: &Raw, arch: Arch) -> Result<Option<BiosConfig>, ConfigError> {
    if !r.bios_support {
        return Ok(None);
    }

    ensure!(arch.supports_bios(), BiosUnsupportedArchSnafu { arch });

    // `nodev` makes partitionIndex and force meaningless, so they go with it.
    // A partitionIndex of 0 is the wire encoding for "not set".
    let stage1 = (r.bios_device != NODEV).then(|| Stage1 {
        device: PathBuf::from(&r.bios_device),
        partition_index: r.partition_index.filter(|&i| i != 0),
        force: r.force,
    });

    Ok(Some(BiosConfig { stage1 }))
}
