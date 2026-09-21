//! Installing limine, given a validated [`LimineInstallConfig`].

mod bios;
mod bootspec;

mod conf;
mod efi;
mod entries;
pub(crate) mod error;

mod nvram;
mod plan;
mod profiles;
mod secure_boot;

use crate::config::LimineInstallConfig;
use error::{InstallError, ReadSnafu, SyncFsSnafu};
use plan::Plan;
use profiles::Profiles;
use snafu::ResultExt as _;
use std::{fs::File, path::Path};

pub(crate) fn run(cfg: &LimineInstallConfig) -> Result<(), InstallError> {
    if let Some(secure_boot) = cfg.secure_boot() {
        secure_boot::check(secure_boot, Path::new(secure_boot::STATE))?;
    }

    let mut plan = Plan::new(&cfg.install_dir, cfg.validate_checksums);

    let limine_conf = conf::generate(&mut plan, cfg, &Profiles::system())?;
    plan.write(&cfg.limine_conf(), limine_conf.clone());

    for (dest, source) in &cfg.additional_files {
        plan.copy(source, &cfg.mount_point.join(dest));
    }

    if let Some(efi) = cfg.target.as_ref().here() {
        efi::plan(&mut plan, cfg, efi);
    }

    if cfg.target.as_ref().there().is_some() {
        bios::plan(&mut plan, cfg);
    }

    plan.apply()?;

    // the rest needs the files it acts on to be in place already
    if let Some(efi) = cfg.target.as_ref().here() {
        efi::activate(cfg, efi, &limine_conf)?;
    }

    if let Some(bios) = cfg.target.as_ref().there() {
        bios::deploy(cfg, bios)?;
    }

    Ok(())
}

/// fat32 offers little in the way of recovery after a crash, and an outage
/// shortly after an update can leave the system unbootable. Flush the boot
/// filesystem whether or not the install got that far.
pub(crate) fn sync(mount_point: &Path) -> Result<(), InstallError> {
    let dir = File::open(mount_point).context(ReadSnafu { path: mount_point })?;

    rustix::fs::syncfs(&dir).context(SyncFsSnafu { path: mount_point })
}
