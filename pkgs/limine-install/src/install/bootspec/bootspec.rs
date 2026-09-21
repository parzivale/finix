use super::raw::Raw;
use crate::install::error::{InstallError, ParseBootSpecSnafu, ReadSnafu};
use serde::Deserialize;
use snafu::ResultExt as _;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Deserialize)]
#[serde(from = "Raw")]
pub(crate) struct BootSpec {
    pub init: PathBuf,
    pub kernel: PathBuf,
    pub kernel_params: Vec<String>,
    pub label: String,
    pub toplevel: PathBuf,
    pub initrd: Option<PathBuf>,
    pub initrd_secrets: Option<PathBuf>,
    pub specialisations: BTreeMap<String, Self>,
    pub xen: Option<Xen>,
}

/// The Xen dom0 extension, once it names a version to label its entries with.
#[derive(Debug)]
pub(crate) struct Xen {
    pub version: String,
    pub params: Vec<String>,
    /// `None` when the multiboot binary is missing. The entry is still listed,
    /// but with no protocol to boot it by.
    pub boot: Option<XenBoot>,
}

impl Xen {
    /// The dom0 parameters as one command line, empty when there are none.
    pub(crate) fn params(&self) -> String {
        self.params.join(" ").trim().to_owned()
    }
}

/// What the Xen entries load, under either protocol.
#[derive(Debug)]
pub(crate) struct XenBoot {
    pub multiboot: PathBuf,
    /// Xen's own EFI binary, which the EFI entry chainloads instead.
    pub efi: Option<PathBuf>,
}

impl BootSpec {
    pub(crate) fn load(path: &Path) -> Result<Self, InstallError> {
        let json = fs::read_to_string(path).context(ReadSnafu { path })?;

        serde_json::from_str(&json).context(ParseBootSpecSnafu { path })
    }

    /// Whether this generation is rendered as a submenu holding its
    /// specialisations, rather than as a single entry. `conf::default_entry`
    /// depends on the same answer, so keep the two in step.
    pub(crate) fn has_specialisations(&self) -> bool {
        !self.specialisations.is_empty()
    }

    /// `init=... <kernel params>`, as both the linux and the multiboot
    /// protocols want it.
    pub(crate) fn cmdline(&self) -> String {
        let mut cmdline = format!("init={}", self.init.display());

        for param in &self.kernel_params {
            cmdline.push(' ');
            cmdline.push_str(param);
        }

        cmdline.trim().to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::BootSpec;

    const TOPLEVEL: &str = "/nix/store/aaa-finix-system";

    fn boot_json(extra: &str) -> String {
        format!(
            r#"{{
              "org.nixos.bootspec.v1": {{
                "init": "{TOPLEVEL}/init",
                "initrd": "/nix/store/bbb-initrd/initrd",
                "kernel": "/nix/store/ccc-linux/Image",
                "kernelParams": ["console=ttyAMA0", "quiet"],
                "label": "finix (Linux 6.18.50)",
                "system": "aarch64-linux",
                "toplevel": "{TOPLEVEL}"
              }},
              "org.nixos.specialisation.v1": {{}}
              {extra}
            }}"#
        )
    }

    fn parse(json: &str) -> BootSpec {
        serde_json::from_str(json).expect("valid boot.json")
    }

    #[test]
    fn flattens_the_bootspec_document() {
        let spec = parse(&boot_json(""));

        assert_eq!(spec.label, "finix (Linux 6.18.50)");
        assert_eq!(spec.kernel.to_str(), Some("/nix/store/ccc-linux/Image"));
        assert!(spec.initrd.is_some());
        assert!(spec.initrd_secrets.is_none());
        assert!(!spec.has_specialisations());
        assert!(spec.xen.is_none());
    }

    /// init comes first, then the kernel params in order.
    #[test]
    fn builds_the_kernel_command_line() {
        assert_eq!(
            parse(&boot_json("")).cmdline(),
            format!("init={TOPLEVEL}/init console=ttyAMA0 quiet")
        );
    }

    #[test]
    fn reads_specialisations_as_nested_generations() {
        let json = format!(
            r#"{{
              "org.nixos.bootspec.v1": {{
                "init": "{TOPLEVEL}/init", "kernel": "/nix/store/ccc-linux/Image",
                "kernelParams": [], "label": "finix", "system": "aarch64-linux",
                "toplevel": "{TOPLEVEL}"
              }},
              "org.nixos.specialisation.v1": {{
                "hardened": {{
                  "org.nixos.bootspec.v1": {{
                    "init": "{TOPLEVEL}-hardened/init", "kernel": "/nix/store/ddd-linux/Image",
                    "kernelParams": ["lockdown=1"], "label": "finix hardened",
                    "system": "aarch64-linux", "toplevel": "{TOPLEVEL}-hardened"
                  }},
                  "org.nixos.specialisation.v1": {{}}
                }}
              }}
            }}"#
        );

        let spec = parse(&json);
        assert!(spec.has_specialisations());

        let hardened = &spec.specialisations["hardened"];
        assert_eq!(hardened.label, "finix hardened");
        assert!(hardened.cmdline().ends_with("lockdown=1"));
    }

    /// A generation predating the extension, or one whose extension names no
    /// version, gets no Xen entries at all.
    #[test]
    fn ignores_a_xen_extension_with_no_version() {
        let spec = parse(&boot_json(
            r#", "org.xenproject.bootspec.v2": {"params": ["dom0_mem=4G"]}"#,
        ));

        assert!(spec.xen.is_none());
    }

    /// Without a multiboot binary on disk there is nothing to boot, so the
    /// entry is listed but carries no protocol.
    #[test]
    fn reads_a_versioned_xen_extension_without_a_multiboot_binary() {
        let spec = parse(&boot_json(
            r#", "org.xenproject.bootspec.v2": {"version": "4.19", "params": ["dom0_mem=4G", "ucode=scan"]}"#,
        ));

        let xen = spec.xen.expect("xen");
        assert_eq!(xen.version, "4.19");
        assert_eq!(xen.params(), "dom0_mem=4G ucode=scan");
        assert!(xen.boot.is_none());
    }
}
