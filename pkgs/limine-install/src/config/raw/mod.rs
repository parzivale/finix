//! The JSON the module's activation script hands us, and its validation into
//! [`LimineInstallConfig`]. Each decision the conversion makes lives in its own
//! submodule; this file only does the plumbing.

mod arch;
mod bios;
mod efi;
mod filesystem;
mod install_dir;
mod secure_boot;
mod target;

use super::{LimineInstallConfig, Setting, error::ConfigError};
use arch::RawArch;
use filesystem::FileSystem;
use secure_boot::RawSecureBoot;
use serde::Deserialize;
use std::{collections::BTreeMap, path::PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[expect(clippy::struct_excessive_bools, reason = "mirrors the wire format")]
pub(super) struct Raw {
    limine_path: PathBuf,
    host_architecture: RawArch,
    file_systems: BTreeMap<String, FileSystem>,

    efi_support: bool,
    efi_mount_point: PathBuf,
    efi_removable: bool,
    can_touch_efi_variables: bool,
    enroll_config: bool,
    secure_boot: RawSecureBoot,
    fwupd_efi_path: Option<PathBuf>,

    bios_support: bool,
    bios_device: String,
    partition_index: Option<u32>,
    force: bool,

    validate_checksums: bool,
    max_generations: u32,
    settings: BTreeMap<String, Setting>,
    extra_entries: String,
    additional_files: BTreeMap<String, PathBuf>,
}

impl TryFrom<Raw> for LimineInstallConfig {
    type Error = ConfigError;

    fn try_from(r: Raw) -> Result<Self, Self::Error> {
        let arch = arch::resolve(&r.host_architecture)?;
        let target = target::resolve(efi::resolve(&r)?, bios::resolve(&r, arch)?)?;
        let install_dir = install_dir::resolve(&r)?;

        Ok(Self {
            limine_path: r.limine_path,
            arch,
            mount_point: r.efi_mount_point,
            install_dir,
            target,
            validate_checksums: r.validate_checksums,
            max_generations: (r.max_generations != 0).then_some(r.max_generations),
            settings: r.settings,
            extra_entries: r.extra_entries,
            additional_files: r.additional_files,
        })
    }
}
