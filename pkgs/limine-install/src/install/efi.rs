use super::{error::InstallError, nvram, plan::Plan, secure_boot};
use crate::config::{EfiDiscovery, EfiInstall, LimineInstallConfig};
use crate::util::{cmd, hash};

use std::{path::Path, process::Command};

/// Put limine's EFI binary where the firmware will find it.
pub(crate) fn plan(plan: &mut Plan, cfg: &LimineInstallConfig, efi: &EfiInstall) {
    let dest = efi.image_path(&cfg.mount_point, cfg.arch.efi_boot_file());

    plan.copy(&cfg.efi_image(), &dest);
}

/// Everything that has to happen once that binary is actually on the ESP:
/// pinning the config to it, signing it, and making the firmware aware of it.
pub(crate) fn activate(
    cfg: &LimineInstallConfig,
    efi: &EfiInstall,
    limine_conf: &str,
) -> Result<(), InstallError> {
    let boot_file = cfg.arch.efi_boot_file();
    let binary = efi.image_path(&cfg.mount_point, boot_file);

    if efi.enroll_config {
        cmd::run(
            Command::new(cfg.limine_binary())
                .arg("enroll-config")
                .arg(&binary)
                .arg(hash::blake2b(limine_conf.as_bytes())),
        )?
        .success()?;
    }

    secure_boot::sign(&efi.secure_boot, &binary, Path::new(secure_boot::STATE))?;

    match &efi.discovery {
        EfiDiscovery::Removable => {}
        EfiDiscovery::Registered => nvram::register(&cfg.mount_point, boot_file)?,
        EfiDiscovery::Unregistered => eprintln!(
            "warning: both boot.loader.efi.canTouchEfiVariables and programs.limine.efiInstallAsRemovable are false,\n  so limine was installed to /efi/limine without an EFI boot entry. This may render the system unbootable."
        ),
    }

    Ok(())
}
