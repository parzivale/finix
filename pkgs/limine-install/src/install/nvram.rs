//! Registering limine with the firmware.
//!
//! `efivar` owns the efivarfs side, including clearing the immutable flag an
//! existing variable carries, and `gpt` owns the partition table; between them
//! we only have to name the entry and keep the boot order.
//!
//! A move off `efivar` is warranted. Its device path handling is hand-rolled
//! -- `format` is a bare u8, and `EFIHardDriveType::Unknown::as_u8` panics --
//! and the crate has been quiet since early 2024. `uefi` (uefi-rs) generates
//! its device path nodes from the spec, types the partition format and
//! signature, and does build and run outside a UEFI target, so it is the
//! better source for the bytes that decide whether the firmware finds us.
//!
//! What it does not carry is `EFI_LOAD_OPTION` or efivarfs access, so the swap
//! costs us the `Boot####` payload assembly and a small efivarfs writer
//! (rustix, which we already depend on, has the ioctls for the immutable flag
//! efivar clears today). Worth doing behind a test that boots off the entry.

use super::error::{
    InstallError, NoSuchPartitionSnafu, NvramSnafu, PartitionTableSnafu, ReadSnafu,
    UnknownPartitionSnafu,
};
use crate::util::mountinfo;
use efivar::{
    VarManager,
    boot::{
        BootEntry, BootEntryAttributes, EFIHardDrive, EFIHardDriveType, FilePath, FilePathList,
    },
    efi::Variable,
};
use snafu::{OptionExt as _, ResultExt as _};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// What the entry is called in the firmware's boot menu.
const LABEL: &str = "Limine";

/// The GPT-flavoured `MBRType` of a hard drive device path node.
const GPT_FORMAT: u8 = 0x02;

/// Point the firmware at the copy of limine we just installed, reusing our own
/// entry so that its position in the boot order survives.
pub(crate) fn register(mount_point: &Path, boot_file: &str) -> Result<(), InstallError> {
    let partition = mountinfo::device_for(mount_point)?;
    let hard_drive = hard_drive(&partition)?;

    let entry = BootEntry {
        attributes: BootEntryAttributes::LOAD_OPTION_ACTIVE,
        description: LABEL.to_owned(),
        file_path_list: Some(FilePathList {
            file_path: FilePath {
                path: format!("\\efi\\limine\\{boot_file}"),
            },
            hard_drive,
        }),
        optional_data: Vec::new(),
    };

    let mut manager = efivar::system();

    let used = used_ids(&*manager)?;
    let id = ours(&*manager, &used).unwrap_or_else(|| free_id(&used));

    manager.add_boot_entry(id, entry).context(NvramSnafu)?;

    // a missing BootOrder is not an error: it means nothing is registered yet.
    let mut order = manager.get_boot_order().unwrap_or_default();
    if !order.contains(&id) {
        order.insert(0, id);
        manager.set_boot_order(order).context(NvramSnafu)?;
    }

    Ok(())
}

/// The id of the entry we wrote last time, if it is still there. Looked up by
/// label, over every Boot#### there is rather than only those in the boot
/// order, so that an entry the firmware has dropped from `BootOrder` is still
/// reused rather than duplicated.
fn ours(manager: &dyn VarManager, used: &[u16]) -> Option<u16> {
    used.iter().copied().find(|id| {
        let variable = Variable::new(&format!("Boot{id:04X}"));

        BootEntry::read(manager, &variable).is_ok_and(|entry| entry.description == LABEL)
    })
}

fn used_ids(manager: &dyn VarManager) -> Result<Vec<u16>, InstallError> {
    let variables = manager.get_all_vars().context(NvramSnafu)?;

    Ok(variables
        .filter_map(|variable| variable.boot_var_id())
        .collect())
}

fn free_id(used: &[u16]) -> u16 {
    (0..=u16::MAX)
        .find(|id| !used.contains(id))
        .unwrap_or_default()
}

/// The hard drive device path node naming the partition the ESP lives on, read
/// straight out of the disk's partition table.
fn hard_drive(partition: &Path) -> Result<EFIHardDrive, InstallError> {
    let number = partition_number(partition)?;
    let disk = disk_of(partition)?;

    let table = gpt::GptConfig::new()
        .writable(false)
        .open(&disk)
        .context(PartitionTableSnafu { path: &disk })?;

    let entry = table
        .partitions()
        .get(&number)
        .context(NoSuchPartitionSnafu { path: disk, number })?;

    Ok(EFIHardDrive {
        partition_number: number,
        partition_start: entry.first_lba,
        partition_size: entry.last_lba + 1 - entry.first_lba,
        partition_sig: entry.part_guid,
        format: GPT_FORMAT,
        sig_type: EFIHardDriveType::Gpt,
    })
}

/// 1-based, and the same number the partition table uses.
fn partition_number(partition: &Path) -> Result<u32, InstallError> {
    let path = sysfs_dir(partition)?.join("partition");
    let number = fs::read_to_string(&path).context(ReadSnafu { path: &path })?;

    number
        .trim()
        .parse()
        .ok()
        .context(UnknownPartitionSnafu { path: partition })
}

/// The whole disk a partition belongs to, via its parent in sysfs.
fn disk_of(partition: &Path) -> Result<PathBuf, InstallError> {
    let sysfs = sysfs_dir(partition)?;

    let disk = sysfs
        .parent()
        .and_then(Path::file_name)
        .context(UnknownPartitionSnafu { path: partition })?;

    Ok(Path::new("/dev").join(disk))
}

fn sysfs_dir(partition: &Path) -> Result<PathBuf, InstallError> {
    let partition = fs::canonicalize(partition).context(ReadSnafu { path: partition })?;
    let name = partition.strip_prefix("/dev").unwrap_or(&partition);

    let sysfs = Path::new("/sys/class/block").join(name);

    fs::canonicalize(&sysfs).context(ReadSnafu { path: sysfs })
}

#[cfg(test)]
mod tests {
    use super::free_id;

    #[test]
    fn takes_the_lowest_free_slot() {
        assert_eq!(free_id(&[]), 0);
        assert_eq!(free_id(&[0, 1, 3]), 2);
        assert_eq!(free_id(&[2, 0, 1]), 3);
    }
}
