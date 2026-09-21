use super::Raw;
use crate::config::error::{ConfigError, NoBootFilesystemSnafu, UnsupportedBootFsTypeSnafu};
use snafu::{OptionExt as _, ensure};
use std::path::PathBuf;

/// The mount point a BIOS-only install has to put its files under.
const BOOT_MOUNT_POINT: &str = "/boot";

/// Where those files then go.
const BIOS_INSTALL_DIR: &str = "/boot/limine";

/// Where limine.conf, the stage 2 binary and the copied kernels go.
///
/// With an ESP the install directory is on it, and the EFI spec already
/// guarantees FAT. Without one, limine has to read `/boot` itself, so that
/// filesystem has to be one it understands.
pub(super) fn resolve(r: &Raw) -> Result<PathBuf, ConfigError> {
    if r.efi_support {
        return Ok(r.efi_mount_point.join("limine"));
    }

    let boot = r
        .file_systems
        .get(BOOT_MOUNT_POINT)
        .context(NoBootFilesystemSnafu)?;

    ensure!(
        boot.is_limine_readable(),
        UnsupportedBootFsTypeSnafu {
            fs_type: boot.fs_type.clone(),
        }
    );

    Ok(PathBuf::from(BIOS_INSTALL_DIR))
}
