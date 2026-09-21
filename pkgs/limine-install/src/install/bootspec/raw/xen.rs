use crate::install::bootspec::{Xen, XenBoot};
use serde::Deserialize;
use std::path::PathBuf;

/// `org.xenproject.bootspec.v2`. Every field is optional: the extension has
/// grown over time, and a generation may carry only part of it.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RawXen {
    efi_path: Option<PathBuf>,
    multiboot_path: Option<PathBuf>,
    #[serde(default)]
    params: Vec<String>,
    version: Option<String>,
}

/// `None` when the extension names no version, which is how the script decides
/// a generation has no Xen entries at all.
pub(super) fn resolve(r: RawXen) -> Option<Xen> {
    Some(Xen {
        version: r.version?,
        params: r.params,
        boot: r
            .multiboot_path
            .filter(|path| !path.as_os_str().is_empty() && path.exists())
            .map(|multiboot| XenBoot {
                multiboot,
                efi: r.efi_path,
            }),
    })
}
