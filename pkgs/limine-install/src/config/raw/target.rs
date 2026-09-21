use crate::config::{
    BiosConfig, EfiInstall,
    error::{ConfigError, NoInstallTargetSnafu},
};
use these::These;

/// At least one of the two install targets has to be enabled.
pub(super) fn resolve(
    efi: Option<EfiInstall>,
    bios: Option<BiosConfig>,
) -> Result<These<EfiInstall, BiosConfig>, ConfigError> {
    Ok(match (efi, bios) {
        (Some(e), Some(b)) => These::Both(e, b),
        (Some(e), None) => These::This(e),
        (None, Some(b)) => These::That(b),
        (None, None) => return NoInstallTargetSnafu.fail(),
    })
}
