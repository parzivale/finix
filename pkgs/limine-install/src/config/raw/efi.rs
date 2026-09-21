use super::{Raw, secure_boot};
use crate::config::{
    EfiDiscovery, EfiInstall,
    error::{ConfigError, SecureBootWithoutEfiSnafu},
};
use snafu::ensure;

/// `None` when `efiSupport` is off; otherwise how firmware is to find limine,
/// plus the two features that only exist on an ESP.
pub(super) fn resolve(r: &Raw) -> Result<Option<EfiInstall>, ConfigError> {
    if !r.efi_support {
        ensure!(!r.secure_boot.enable, SecureBootWithoutEfiSnafu);
        return Ok(None);
    }

    let discovery = match (r.efi_removable, r.can_touch_efi_variables) {
        (true, _) => EfiDiscovery::Removable,
        (false, true) => EfiDiscovery::Registered,
        (false, false) => EfiDiscovery::Unregistered,
    };

    Ok(Some(EfiInstall {
        discovery,
        enroll_config: r.enroll_config,
        secure_boot: secure_boot::resolve(&r.secure_boot, r.fwupd_efi_path.as_deref()),
    }))
}
