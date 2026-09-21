use super::{
    error::{BiosInstallSnafu, InstallError},
    plan::Plan,
};
use crate::{
    config::{BiosConfig, LimineInstallConfig},
    util::cmd,
};
use snafu::ResultExt as _;
use std::process::Command;

/// Stage 2 goes next to limine.conf, where stage 1 will look for it.
pub(crate) fn plan(plan: &mut Plan, cfg: &LimineInstallConfig) {
    plan.copy(&cfg.bios_stage2(), &cfg.install_dir.join("limine-bios.sys"));
}

/// Write stage 1 to the disk, once stage 2 is there for it to find.
pub(crate) fn deploy(cfg: &LimineInstallConfig, bios: &BiosConfig) -> Result<(), InstallError> {
    let Some(stage1) = &bios.stage1 else {
        eprintln!(
            "note: programs.limine.biosSupport is set, but device is set to nodev, only the stage 2 bootloader will be installed."
        );

        return Ok(());
    };

    let mut command = Command::new(cfg.limine_binary());
    command.arg("bios-install").arg(&stage1.device);

    if let Some(index) = stage1.partition_index {
        command.arg(index.to_string());
    }

    if stage1.force {
        command.arg("--force");
    }

    cmd::run(&mut command)
        .and_then(cmd::Output::success)
        .context(BiosInstallSnafu)?;

    Ok(())
}
