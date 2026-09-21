use crate::config::{
    Arch,
    error::{ConfigError, UnsupportedArchSnafu},
};
use serde::Deserialize;

/// `pkgs.stdenv.hostPlatform.parsed.cpu`. Wide enough to describe CPUs limine
/// has never heard of, hence the narrowing below.
#[derive(Deserialize)]
pub(super) struct RawArch {
    family: String,
    bits: u32,
    arch: Option<String>,
}

/// Which limine binaries this CPU needs, or a hard error.
///
/// The script only decides this once it is about to copy the EFI binary
/// (`limine-install.py:486-500`), by which point it has already written to the
/// ESP; and an `x86` CPU that is neither 32- nor 64-bit falls through its
/// `if`/`elif` with an empty filename rather than reaching the raise.
pub(super) fn resolve(r: &RawArch) -> Result<Arch, ConfigError> {
    Ok(match (r.family.as_str(), r.bits, r.arch.as_deref()) {
        ("x86", 32, _) => Arch::I686,
        ("x86", 64, _) => Arch::X86_64,
        ("arm", 64, Some("armv8-a")) => Arch::Aarch64,
        _ => {
            return UnsupportedArchSnafu {
                family: r.family.clone(),
                bits: r.bits,
                arch: r.arch.clone(),
            }
            .fail();
        }
    })
}
