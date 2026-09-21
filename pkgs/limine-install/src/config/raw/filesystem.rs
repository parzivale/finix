use serde::Deserialize;

/// An entry of the module's `fileSystems`. Only ever consulted to find out what
/// `/boot` is formatted as, so every other field of the submodule is ignored.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FileSystem {
    pub(super) fs_type: String,
}

impl FileSystem {
    /// Whether limine can read this filesystem well enough to load limine.conf
    /// and the kernels copied next to it. Limine understands FAT12/16/32 and
    /// ISO9660; only the former is reachable for an installed system.
    pub(super) fn is_limine_readable(&self) -> bool {
        self.fs_type.starts_with("vfat")
    }
}
