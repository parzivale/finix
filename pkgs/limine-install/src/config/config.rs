use super::{Setting, raw::Raw};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fmt,
    path::{Path, PathBuf},
};
use these::These;

#[derive(Debug, Deserialize)]
#[serde(try_from = "Raw")]
pub(crate) struct LimineInstallConfig {
    pub limine_path: PathBuf,
    pub arch: Arch,
    /// `efiMountPoint`; used unconditionally by the additionalFiles copy loop.
    pub mount_point: PathBuf,
    /// Where limine.conf, the stage 2 binary and the copied kernels go: on the
    /// ESP when EFI is enabled, otherwise `/boot/limine`. Resolved during
    /// validation, which is also where a non-FAT `/boot` is rejected.
    pub install_dir: PathBuf,

    /// EFI, BIOS, or hybrid. Use `.as_ref().here()` / `.as_ref().there()`.
    pub target: These<EfiInstall, BiosConfig>,

    /// Append a blake2b digest to every `boot():` URI we emit.
    pub validate_checksums: bool,
    /// `None` = unlimited (wire value 0).
    pub max_generations: Option<u32>,

    /// limine.conf's global section, verbatim. Rendered in key order, with
    /// `default_entry` appended when the module did not set it.
    pub settings: BTreeMap<String, Setting>,
    pub extra_entries: String,
    /// dest (relative to `mount_point`) -> source path
    pub additional_files: BTreeMap<String, PathBuf>,
}

impl LimineInstallConfig {
    /// limine's own tool, which deploys stage 1 and enrols the config hash.
    pub(crate) fn limine_binary(&self) -> PathBuf {
        self.limine_path.join("bin/limine")
    }

    /// The EFI binary limine ships for our architecture.
    pub(crate) fn efi_image(&self) -> PathBuf {
        self.limine_path
            .join("share/limine")
            .join(self.arch.efi_boot_file())
    }

    /// The BIOS stage 2, which is copied next to limine.conf.
    pub(crate) fn bios_stage2(&self) -> PathBuf {
        self.limine_path.join("share/limine/limine-bios.sys")
    }

    pub(crate) fn limine_conf(&self) -> PathBuf {
        self.install_dir.join("limine.conf")
    }

    pub(crate) fn efi_support(&self) -> bool {
        self.target.as_ref().here().is_some()
    }

    /// `None` when there is no ESP, or when signing was not asked for.
    pub(crate) fn secure_boot(&self) -> Option<&SecureBoot> {
        self.target.as_ref().here().map(|efi| &efi.secure_boot)
    }
}

/// The CPU limine is being installed for. The module asserts x86 and aarch64
/// only, and the wire format's `family`/`bits`/`arch` triple can express far
/// more than limine ships binaries for, so it is narrowed during validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Arch {
    I686,
    X86_64,
    Aarch64,
}

impl Arch {
    /// The EFI binary limine ships for this architecture.
    pub(crate) const fn efi_boot_file(self) -> &'static str {
        match self {
            Self::I686 => "BOOTIA32.EFI",
            Self::X86_64 => "BOOTX64.EFI",
            Self::Aarch64 => "BOOTAA64.EFI",
        }
    }

    /// Limine's BIOS stage 1 exists only for x86.
    pub(crate) const fn supports_bios(self) -> bool {
        matches!(self, Self::I686 | Self::X86_64)
    }
}

impl fmt::Display for Arch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::I686 => "i686",
            Self::X86_64 => "x86_64",
            Self::Aarch64 => "aarch64",
        })
    }
}

/// The EFI half of an install. Everything that is meaningless without an ESP
/// hangs off here rather than off the top-level config.
#[derive(Debug)]
pub(crate) struct EfiInstall {
    pub discovery: EfiDiscovery,
    /// Hash limine.conf and hand it to `limine enroll-config`.
    pub enroll_config: bool,
    pub secure_boot: SecureBoot,
}

/// How limine is made discoverable by EFI firmware.
#[derive(Debug)]
pub(crate) enum EfiDiscovery {
    /// Copied to `/EFI/BOOT/BOOT{X64,IA32,AA64}.EFI` — the fallback path every
    /// firmware probes, so no NVRAM entry is needed
    /// (`efiInstallAsRemovable = true`; `canTouchEfiVariables` is moot).
    Removable,
    /// Installed under `/EFI/limine/` and registered in NVRAM.
    Registered,
    /// Installed under `/EFI/limine/` with **no** NVRAM entry; the user must
    /// add one themselves. The Python script only warns about this.
    Unregistered,
}

impl EfiDiscovery {
    /// The directory under `/efi` the firmware will look in.
    pub(crate) const fn directory(&self) -> &'static str {
        match self {
            Self::Removable => "boot",
            Self::Registered | Self::Unregistered => "limine",
        }
    }
}

impl EfiInstall {
    /// Where limine's EFI binary goes on the ESP.
    pub(crate) fn image_path(&self, mount_point: &Path, boot_file: &str) -> PathBuf {
        mount_point
            .join("efi")
            .join(self.discovery.directory())
            .join(boot_file)
    }
}

/// The BIOS half of an install.
#[derive(Debug)]
pub(crate) struct BiosConfig {
    /// `None` when `biosDevice` is `"nodev"`: stage 2 is copied into the
    /// install directory, but no stage 1 is written to any disk.
    pub stage1: Option<Stage1>,
}

/// Deploying limine's stage 1 to a disk. All three fields are only ever
/// `limine bios-install` arguments, so they live or die together.
#[derive(Debug)]
pub(crate) struct Stage1 {
    pub device: PathBuf,
    /// 1-based index of the dedicated stage 2 partition, if any.
    pub partition_index: Option<u32>,
    /// Pass `--force`, overriding limine's own safety checks.
    pub force: bool,
}

/// Signing the EFI binary with sbctl. Only reachable through [`EfiInstall`],
/// because secure boot without an ESP is meaningless.
#[derive(Debug)]
pub(crate) enum SecureBoot {
    Disabled,
    Enabled {
        /// The `sbctl` binary itself, resolved out of its store path.
        sbctl: PathBuf,
        keys: KeyPolicy,
        /// fwupd's store path; its EFI binaries get signed too when present.
        fwupd: Option<PathBuf>,
    },
}

/// What to do when `/var/lib/sbctl` holds no keys yet.
#[derive(Debug)]
pub(crate) enum KeyPolicy {
    /// Bail out and tell the user to generate them.
    Require,
    /// Generate them, then enrol them with these extra `sbctl` arguments if
    /// `Some`. Enrolment is unreachable without generation, which is why it is
    /// nested here rather than being a sibling flag.
    Generate { enroll: Option<Vec<String>> },
}

#[cfg(test)]
mod tests {
    use super::{Arch, EfiDiscovery, KeyPolicy, LimineInstallConfig, SecureBoot};
    use serde_json::{Value, json};
    use std::path::Path;

    /// The shape `modules/programs/limine/providers.bootloader.nix` emits.
    fn wire() -> Value {
        json!({
            "additionalFiles": {},
            "biosDevice": "nodev",
            "biosSupport": false,
            "canTouchEfiVariables": false,
            "efiMountPoint": "/boot",
            "efiRemovable": true,
            "efiSupport": true,
            "enrollConfig": false,
            "extraEntries": "",
            "fileSystems": {},
            "force": false,
            "fwupdEfiPath": null,
            "hostArchitecture": {"family": "arm", "bits": 64, "arch": "armv8-a"},
            "liminePath": "/nix/store/aaa-limine",
            "maxGenerations": 0,
            "partitionIndex": null,
            "secureBoot": {
                "enable": false, "autoGenerateKeys": false,
                "autoEnrollKeys": {"enable": false, "extraArgs": []},
                "sbctl": "/nix/store/bbb-sbctl"
            },
            "settings": {},
            "validateChecksums": true
        })
    }

    fn try_parse(overrides: Value) -> Result<LimineInstallConfig, String> {
        let mut json = wire();

        let Value::Object(overrides) = overrides else {
            panic!("overrides must be an object");
        };

        for (key, value) in overrides {
            json[key] = value;
        }

        serde_json::from_value(json).map_err(|error| error.to_string())
    }

    fn parse(overrides: Value) -> LimineInstallConfig {
        try_parse(overrides).expect("a valid config")
    }

    #[test]
    fn accepts_what_the_module_emits() {
        let cfg = parse(json!({}));

        assert_eq!(cfg.arch, Arch::Aarch64);
        assert!(cfg.efi_support());
        assert_eq!(cfg.install_dir, Path::new("/boot/limine"));
    }

    /// Wire value 0 means "keep every generation", not "keep none".
    #[test]
    fn reads_zero_max_generations_as_unlimited() {
        assert_eq!(parse(json!({})).max_generations, None);
        assert_eq!(parse(json!({"maxGenerations": 5})).max_generations, Some(5));
    }

    #[test]
    fn derives_the_paths_it_installs_from() {
        let cfg = parse(json!({}));

        assert_eq!(
            cfg.limine_binary(),
            Path::new("/nix/store/aaa-limine/bin/limine")
        );
        assert_eq!(
            cfg.efi_image(),
            Path::new("/nix/store/aaa-limine/share/limine/BOOTAA64.EFI")
        );
        assert_eq!(cfg.limine_conf(), Path::new("/boot/limine/limine.conf"));
    }

    #[test]
    fn removable_installs_go_to_the_firmware_fallback_path() {
        let cfg = parse(json!({}));
        let efi = cfg.target.as_ref().here().expect("efi");

        assert!(matches!(efi.discovery, EfiDiscovery::Removable));
        assert_eq!(
            efi.image_path(Path::new("/boot"), "BOOTAA64.EFI"),
            Path::new("/boot/efi/boot/BOOTAA64.EFI")
        );
    }

    #[test]
    fn registered_installs_go_under_their_own_directory() {
        let cfg = parse(json!({"efiRemovable": false, "canTouchEfiVariables": true}));
        let efi = cfg.target.as_ref().here().expect("efi");

        assert!(matches!(efi.discovery, EfiDiscovery::Registered));
        assert_eq!(
            efi.image_path(Path::new("/boot"), "BOOTAA64.EFI"),
            Path::new("/boot/efi/limine/BOOTAA64.EFI")
        );
    }

    /// Neither the fallback path nor an NVRAM entry: allowed, but only so the
    /// install can warn about it.
    #[test]
    fn unregistered_is_neither() {
        let cfg = parse(json!({"efiRemovable": false}));
        let efi = cfg.target.as_ref().here().expect("efi");

        assert!(matches!(efi.discovery, EfiDiscovery::Unregistered));
    }

    #[test]
    fn resolves_the_sbctl_binary_out_of_its_store_path() {
        let cfg = parse(json!({
            "secureBoot": {
                "enable": true, "autoGenerateKeys": true,
                "autoEnrollKeys": {"enable": true, "extraArgs": ["--microsoft"]},
                "sbctl": "/nix/store/bbb-sbctl"
            }
        }));

        let Some(SecureBoot::Enabled { sbctl, keys, .. }) = cfg.secure_boot() else {
            panic!("expected secure boot");
        };

        assert_eq!(sbctl, Path::new("/nix/store/bbb-sbctl/bin/sbctl"));

        let KeyPolicy::Generate { enroll } = keys else {
            panic!("expected key generation");
        };
        assert_eq!(
            enroll.as_deref(),
            Some(["--microsoft".to_owned()].as_slice())
        );
    }

    /// Without an ESP, limine has to read /boot itself, so it has to be one of
    /// the filesystems limine understands.
    #[test]
    fn a_bios_only_install_needs_a_fat_boot_filesystem() {
        let bios_only = json!({
            "efiSupport": false, "biosSupport": true,
            "hostArchitecture": {"family": "x86", "bits": 64, "arch": null}
        });

        let mut with_vfat = bios_only.clone();
        with_vfat["fileSystems"] = json!({"/boot": {"fsType": "vfat"}});
        assert_eq!(parse(with_vfat).install_dir, Path::new("/boot/limine"));

        let mut with_ext4 = bios_only.clone();
        with_ext4["fileSystems"] = json!({"/boot": {"fsType": "ext4"}});
        assert!(
            try_parse(with_ext4)
                .unwrap_err()
                .contains("limine cannot read ext4")
        );

        assert!(
            try_parse(bios_only)
                .unwrap_err()
                .contains("none is configured")
        );
    }

    #[test]
    fn rejects_a_cpu_limine_has_no_binary_for() {
        let error = try_parse(json!({
            "hostArchitecture": {"family": "riscv", "bits": 64, "arch": null}
        }))
        .unwrap_err();

        assert!(error.contains("unsupported CPU"), "{error}");
    }

    #[test]
    fn rejects_an_install_with_no_target() {
        let error = try_parse(json!({"efiSupport": false, "biosSupport": false})).unwrap_err();

        assert!(
            error.contains("neither efiSupport nor biosSupport"),
            "{error}"
        );
    }

    /// limine's BIOS stage 1 is x86-only.
    #[test]
    fn rejects_bios_on_a_cpu_without_a_stage_1() {
        let error = try_parse(json!({"biosSupport": true})).unwrap_err();

        assert!(error.contains("no BIOS stage 1"), "{error}");
    }
}
