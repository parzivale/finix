use super::Arch;
use snafu::Snafu;

/// Something in the install config is internally inconsistent.
#[derive(Debug, Snafu)]
#[snafu(visibility(pub(super)))]
pub(crate) enum ConfigError {
    /// Neither install target was requested, so there is nothing to do.
    #[snafu(display("neither efiSupport nor biosSupport is enabled"))]
    NoInstallTarget,
    /// Without an ESP there is nowhere to put limine.conf and the kernels.
    #[snafu(display(
        "BIOS-only installs require a FAT filesystem mounted at /boot, but none is configured"
    ))]
    NoBootFilesystem,
    /// `/boot` exists but limine cannot read it.
    #[snafu(display(
        "BIOS-only installs require /boot to be a FAT filesystem; limine cannot read {fs_type}"
    ))]
    UnsupportedBootFsType {
        /// The `fsType` of the filesystem mounted at `/boot`.
        fs_type: String,
    },
    /// Limine ships no binary for this CPU.
    #[snafu(display(
        "unsupported CPU: {family} family, {bits}-bit, arch {}",
        arch.as_deref().unwrap_or("unknown"),
    ))]
    UnsupportedArch {
        /// `hostArchitecture.family`, e.g. `x86`, `arm`, `riscv`.
        family: String,
        /// `hostArchitecture.bits`, 32 or 64.
        bits: u32,
        /// `hostArchitecture.arch`, e.g. `armv8-a`. Not every CPU declares one.
        arch: Option<String>,
    },
    /// Limine's BIOS stage 1 is x86-only.
    #[snafu(display("biosSupport is enabled, but limine has no BIOS stage 1 for {arch}"))]
    BiosUnsupportedArch {
        /// The architecture being installed for.
        arch: Arch,
    },
    /// There would be no EFI binary to sign.
    #[snafu(display("secureBoot.enable is true but efiSupport is false"))]
    SecureBootWithoutEfi,
}
