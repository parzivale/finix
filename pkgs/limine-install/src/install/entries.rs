use super::{
    bootspec::{BootSpec, Xen},
    error::{InstallError, ReadSnafu, RemoveSnafu, XenWithoutEfiPathSnafu},
    plan::Plan,
    profiles::Profiles,
};
use crate::util::cmd;
use jiff::{Timestamp, tz::TimeZone};
use rustix::{fs::Mode, process};
use snafu::{OptionExt as _, ResultExt as _};
use std::{
    fs,
    os::unix::fs::MetadataExt as _,
    path::{Path, PathBuf},
    process::Command,
};

/// Where the kernels, initrds and their secrets are copied to.
const KERNELS: &str = "kernels";

/// The menu entries for one generation: its Xen entries first, then the
/// generation itself, then its specialisations.
pub(crate) fn generate(
    plan: &mut Plan,
    profiles: &Profiles,
    profile: &str,
    generation: u32,
    efi_support: bool,
    expanded: bool,
) -> Result<String, InstallError> {
    let link = profiles.generation_path(profile, generation);
    let time = built_at(&link)?;
    let spec = BootSpec::load(&link.join("boot.json"))?;

    let mut blocks = Vec::new();

    if let Some(xen) = &spec.xen {
        if efi_support {
            blocks.push(xen_entry(plan, 2, &spec, xen, generation, &time, true)?);
        }
        blocks.push(xen_entry(plan, 2, &spec, xen, generation, &time, false)?);
    }

    // A generation with specialisations becomes a submenu holding them.
    let depth = if spec.has_specialisations() { 3 } else { 2 };

    if spec.has_specialisations() {
        let marker = if expanded { "+" } else { "" };
        blocks.push(format!(
            "{}{marker}Generation {generation}\n",
            "/".repeat(depth - 1)
        ));
        blocks.push(linux_entry(plan, depth, &spec, "Default", &time)?);
    } else {
        let label = format!("Generation {generation}");
        blocks.push(linux_entry(plan, depth, &spec, &label, &time)?);
    }

    for (name, spec) in &spec.specialisations {
        blocks.push(linux_entry(plan, depth, spec, name, &time)?);
    }

    Ok(blocks.concat())
}

fn linux_entry(
    plan: &mut Plan,
    levels: usize,
    spec: &BootSpec,
    label: &str,
    time: &str,
) -> Result<String, InstallError> {
    let mut lines = vec![
        format!("{}{label}", "/".repeat(levels)),
        "protocol: linux".to_owned(),
        format!("comment: {}, built on {time}", spec.label),
        format!("kernel_path: {}", plan.copied_uri(&spec.kernel, KERNELS)?),
        format!("cmdline: {}", spec.cmdline()),
    ];

    if let Some(initrd) = &spec.initrd {
        lines.push(format!(
            "module_path: {}",
            plan.copied_uri(initrd, KERNELS)?
        ));
    }

    if let Some(secrets) = &spec.initrd_secrets
        && let Some(path) = build_secrets(plan, spec, secrets, label)?
    {
        lines.push(format!("module_path: {}", plan.copied_uri(&path, KERNELS)?));
    }

    Ok(block(&lines))
}

/// Xen is loaded as the executable, with the kernel and initrd as modules.
/// Under EFI that goes through Xen's own EFI binary and its `.cfg`, because
/// limine cannot find an entry point in Xen's multiboot binary (limine #482),
/// and multiboot1 does not work under EFI at all (limine #483).
fn xen_entry(
    plan: &mut Plan,
    levels: usize,
    spec: &BootSpec,
    xen: &Xen,
    generation: u32,
    time: &str,
    efi: bool,
) -> Result<String, InstallError> {
    let version = &xen.version;
    let suffix = if efi { " EFI" } else { "" };

    let mut lines = vec![
        format!(
            "{}Generation {generation} with Xen {version}{suffix}",
            "/".repeat(levels)
        ),
        format!("comment: Xen {version} {}, built on {time}", spec.label),
    ];

    let Some(boot) = &xen.boot else {
        return Ok(block(&lines));
    };

    let target = format!("xen/{generation}");

    if efi {
        let binary = boot
            .efi
            .as_deref()
            .context(XenWithoutEfiPathSnafu { generation })?;

        lines.push("protocol: efi".to_owned());
        lines.push(format!(
            "path: {}",
            xen_efi_files(plan, spec, xen, binary, generation)?
        ));

        return Ok(block(&lines));
    }

    lines.push("protocol: multiboot".to_owned());
    lines.push(format!(
        "path: {}",
        plan.copied_uri(&boot.multiboot, &target)?
    ));

    // The leading `--` works around the first argument being dropped.
    if !xen.params.is_empty() {
        lines.push(format!("cmdline: -- {}", xen.params()));
    }

    lines.push(format!(
        "module_path: {}",
        plan.copied_uri(&spec.kernel, KERNELS)?
    ));
    lines.push(format!("module_string: -- {}", spec.cmdline()));

    if let Some(initrd) = &spec.initrd {
        lines.push(format!(
            "module_path: {}",
            plan.copied_uri(initrd, KERNELS)?
        ));
    }

    Ok(block(&lines))
}

/// Lay out the `xen/<generation>` directory that Xen's EFI binary reads, and
/// return the URI of the binary itself.
fn xen_efi_files(
    plan: &mut Plan,
    spec: &BootSpec,
    xen: &Xen,
    efi_path: &Path,
    generation: u32,
) -> Result<String, InstallError> {
    let target = format!("xen/{generation}");

    let uri = plan.copied_uri(efi_path, &target)?;
    let config_path = plan.dest_path(efi_path, &target).with_extension("cfg");

    let mut lines = vec![
        format!("default=nixos{generation}"),
        String::new(),
        format!("[nixos{generation}]"),
    ];

    if !xen.params.is_empty() {
        lines.push(format!("options={}", xen.params()));
    }

    let kernel = plan.dest_path(&spec.kernel, &target);
    plan.copy(&spec.kernel, &kernel);
    lines.push(format!("kernel={} {}", file_name(&kernel), spec.cmdline()));

    if let Some(initrd) = &spec.initrd {
        let dest = plan.dest_path(initrd, &target);
        plan.copy(initrd, &dest);
        lines.push(format!("ramdisk={}", file_name(&dest)));
    }

    plan.write(&config_path, block(&lines));

    Ok(uri)
}

/// Run the generation's secrets script and put the result next to the kernels.
/// A failure here is not fatal: old generations routinely no longer have the
/// secrets they were built with.
fn build_secrets(
    plan: &mut Plan,
    spec: &BootSpec,
    secrets: &Path,
    label: &str,
) -> Result<Option<PathBuf>, InstallError> {
    let name = format!("{}-secrets", file_name(&spec.toplevel));
    let dest = plan.install_dir().join(KERNELS).join(&name);

    let previous = process::umask(Mode::from_bits_truncate(0o137));
    let tmp = std::env::temp_dir().join(format!("{}-{name}", std::process::id()));

    let failure = match cmd::run(Command::new(secrets).arg(&tmp)) {
        Ok(output) if output.status.success() => None,
        Ok(output) => Some(output.text),
        Err(error) => Some(error.to_string()),
    };

    if let Some(reason) = failure {
        eprintln!(
            "warning: failed to create initrd secrets for {label:?}: {}",
            reason.trim()
        );
        println!("note: if this is an older generation there is nothing to worry about");
    }

    // read it out and drop it rather than leaving secrets in /tmp until apply
    let built = tmp.exists();
    if built {
        let contents = fs::read(&tmp).context(ReadSnafu { path: &tmp })?;
        fs::remove_file(&tmp).context(RemoveSnafu { path: &tmp })?;
        plan.write(&dest, contents);
    }

    process::umask(previous);
    Ok(built.then_some(dest))
}

fn block(lines: &[String]) -> String {
    let mut block = lines.join("\n");
    block.push('\n');
    block
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}

fn built_at(link: &Path) -> Result<String, InstallError> {
    let mtime = fs::symlink_metadata(link)
        .context(ReadSnafu { path: link })?
        .mtime();

    let stamp = Timestamp::from_second(mtime).unwrap_or(Timestamp::UNIX_EPOCH);
    Ok(stamp
        .to_zoned(TimeZone::system())
        .strftime("%F %H:%M:%S")
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::generate;
    use crate::install::{plan::Plan, profiles::Profiles};
    use std::{fs, path::PathBuf};
    use tempfile::TempDir;

    /// A profile tree with one generation, over a stand-in for the store so
    /// that copied files get the same `<hash>-<name>` treatment they would in
    /// the real one.
    struct Fixture {
        dir: TempDir,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                dir: TempDir::new().expect("temp dir"),
            }
        }

        fn store(&self) -> PathBuf {
            self.dir.path().join("store")
        }

        /// Give the store a file at `<name>/<file>`, so it can be hashed.
        fn store_file(&self, name: &str, file: &str, contents: &[u8]) {
            let dir = self.store().join(name);
            fs::create_dir_all(&dir).expect("mkdir");
            fs::write(dir.join(file), contents).expect("write");
        }

        /// Install `boot_json` as generation 1 of the system profile.
        fn generation(&self, boot_json: &str) {
            let toplevel = self.dir.path().join("toplevel");
            fs::create_dir_all(&toplevel).expect("mkdir");
            fs::write(toplevel.join("boot.json"), boot_json).expect("boot.json");

            let profiles = self.dir.path().join("profiles");
            fs::create_dir_all(&profiles).expect("mkdir");
            std::os::unix::fs::symlink(&toplevel, profiles.join("system-1-link")).expect("symlink");
        }

        fn plan(&self, validate_checksums: bool) -> Plan {
            Plan::new(&self.dir.path().join("boot/limine"), validate_checksums)
        }

        fn render_with(&self, plan: &mut Plan, expanded: bool) -> String {
            generate(
                plan,
                &Profiles::new(&self.dir.path().join("profiles")),
                "system",
                1,
                false,
                expanded,
            )
            .expect("entries")
        }

        fn render(&self, expanded: bool) -> String {
            self.render_with(&mut self.plan(false), expanded)
        }
    }

    fn boot_json(fixture: &Fixture, specialisations: &str) -> String {
        boot_json_with(fixture, specialisations, "")
    }

    fn boot_json_with(fixture: &Fixture, specialisations: &str, extension: &str) -> String {
        let store = fixture.store().display().to_string();

        format!(
            r#"{{
              "org.nixos.bootspec.v1": {{
                "init": "/nix/store/aaa-finix-system/init",
                "initrd": "{store}/ccc-initrd/initrd",
                "kernel": "{store}/bbb-linux/Image",
                "kernelParams": ["console=ttyAMA0", "quiet"],
                "label": "finix (Linux 6.18.50)",
                "system": "aarch64-linux",
                "toplevel": "/nix/store/aaa-finix-system"
              }},
              "org.nixos.specialisation.v1": {{{specialisations}}}
              {extension}
            }}"#
        )
    }

    fn specialisation(fixture: &Fixture) -> String {
        format!(
            r#""hardened": {{
              "org.nixos.bootspec.v1": {{
                "init": "/nix/store/ddd-hardened/init",
                "kernel": "{}/bbb-linux/Image",
                "kernelParams": ["lockdown=1"],
                "label": "finix hardened",
                "system": "aarch64-linux",
                "toplevel": "/nix/store/ddd-hardened"
              }},
              "org.nixos.specialisation.v1": {{}}
            }}"#,
            fixture.store().display()
        )
    }

    /// Everything but the `built on` timestamp, which is the generation
    /// symlink's mtime.
    fn without_timestamp(entries: &str) -> String {
        entries
            .lines()
            .map(|line| match line.split_once(", built on ") {
                Some((head, _)) => format!("{head}, built on <time>"),
                None => line.to_owned(),
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn renders_a_generation_as_one_entry() {
        let fixture = Fixture::new();
        fixture.generation(&boot_json(&fixture, ""));

        assert_eq!(
            without_timestamp(&fixture.render(false)),
            "\
//Generation 1
protocol: linux
comment: finix (Linux 6.18.50), built on <time>
kernel_path: boot():/limine/kernels/bbb-linux-Image
cmdline: init=/nix/store/aaa-finix-system/init console=ttyAMA0 quiet
module_path: boot():/limine/kernels/ccc-initrd-initrd"
        );
    }

    /// Specialisations turn the generation into a submenu: it gains a header,
    /// its own entry becomes "Default", and everything drops a level.
    #[test]
    fn renders_specialisations_as_a_submenu() {
        let fixture = Fixture::new();
        fixture.generation(&boot_json(&fixture, &specialisation(&fixture)));

        let entries = without_timestamp(&fixture.render(true));
        let lines: Vec<&str> = entries.lines().collect();

        assert_eq!(lines[0], "//+Generation 1");
        assert_eq!(lines[1], "///Default");
        assert!(entries.contains("\n///hardened\n"), "{entries}");
        assert!(entries.contains("cmdline: init=/nix/store/ddd-hardened/init lockdown=1"));
    }

    /// The newest generation in the menu is the expanded one; the rest are not.
    #[test]
    fn only_the_newest_generation_is_expanded() {
        let fixture = Fixture::new();
        fixture.generation(&boot_json(&fixture, &specialisation(&fixture)));

        assert!(fixture.render(true).starts_with("//+Generation 1"));
        assert!(fixture.render(false).starts_with("//Generation 1"));
    }

    /// With checksums on, every referenced file carries a blake2b digest that
    /// limine verifies before booting it.
    #[test]
    fn appends_digests_when_checksums_are_on() {
        let fixture = Fixture::new();
        fixture.generation(&boot_json(&fixture, ""));
        fixture.store_file("bbb-linux", "Image", b"kernel");
        fixture.store_file("ccc-initrd", "initrd", b"initrd");

        let entries = fixture.render_with(&mut fixture.plan(true), false);

        let digest = entries
            .lines()
            .find_map(|line| line.strip_prefix("kernel_path: "))
            .and_then(|uri| uri.split_once('#'))
            .map(|(_, digest)| digest.to_owned())
            .expect("a digest");

        assert_eq!(digest, crate::util::hash::blake2b(b"kernel"));
    }

    /// A Xen extension naming a multiboot binary that is actually there.
    fn xen(fixture: &Fixture, multiboot: bool, efi: bool) -> String {
        let store = fixture.store();

        if multiboot {
            fixture.store_file("eee-xen", "xen", b"multiboot");
        }
        if efi {
            fixture.store_file("eee-xen", "xen.efi", b"efi");
        }

        format!(
            r#", "org.xenproject.bootspec.v2": {{
              "version": "4.19",
              "params": ["dom0_mem=4G", "ucode=scan"],
              "multibootPath": "{0}/eee-xen/xen",
              "efiPath": "{0}/eee-xen/xen.efi"
            }}"#,
            store.display()
        )
    }

    /// Xen loads as the executable with the kernel and initrd as modules. The
    /// leading `--` on both cmdlines works around limine dropping the first
    /// argument.
    #[test]
    fn renders_a_xen_multiboot_entry() {
        let fixture = Fixture::new();
        let extension = xen(&fixture, true, false);
        fixture.generation(&boot_json_with(&fixture, "", &extension));

        let entries = without_timestamp(&fixture.render(false));
        let xen_entry: Vec<&str> = entries
            .lines()
            .skip_while(|line| !line.contains("with Xen"))
            .take_while(|line| *line != "//Generation 1")
            .collect();

        assert_eq!(
            xen_entry,
            [
                "//Generation 1 with Xen 4.19",
                "comment: Xen 4.19 finix (Linux 6.18.50), built on <time>",
                "protocol: multiboot",
                "path: boot():/limine/xen/1/eee-xen-xen",
                "cmdline: -- dom0_mem=4G ucode=scan",
                "module_path: boot():/limine/kernels/bbb-linux-Image",
                "module_string: -- init=/nix/store/aaa-finix-system/init console=ttyAMA0 quiet",
                "module_path: boot():/limine/kernels/ccc-initrd-initrd",
            ]
        );
    }

    /// Under EFI, limine chainloads Xen's own EFI binary instead, because it
    /// cannot find an entry point in the multiboot one (limine #482).
    #[test]
    fn renders_a_xen_efi_entry_when_efi_is_supported() {
        let fixture = Fixture::new();
        let extension = xen(&fixture, true, true);
        fixture.generation(&boot_json_with(&fixture, "", &extension));

        let mut plan = fixture.plan(false);
        let entries = generate(
            &mut plan,
            &Profiles::new(&fixture.dir.path().join("profiles")),
            "system",
            1,
            true,
            false,
        )
        .expect("entries");

        // the EFI entry comes first, then the multiboot one
        assert!(
            entries.contains("//Generation 1 with Xen 4.19 EFI\n"),
            "{entries}"
        );
        assert!(entries.contains("protocol: efi\npath: boot():/limine/xen/1/eee-xen-xen.efi"));
        assert!(entries.contains("protocol: multiboot"));
    }

    /// Xen's EFI binary reads this beside itself, so the kernel and initrd go
    /// in the same directory under their own names.
    #[test]
    fn writes_the_xen_efi_config_beside_its_binary() {
        let fixture = Fixture::new();
        let extension = xen(&fixture, true, true);
        fixture.generation(&boot_json_with(&fixture, "", &extension));

        let mut plan = fixture.plan(false);
        generate(
            &mut plan,
            &Profiles::new(&fixture.dir.path().join("profiles")),
            "system",
            1,
            true,
            false,
        )
        .expect("entries");

        let written = plan
            .actions()
            .iter()
            .find_map(|action| match action {
                crate::install::plan::Action::Write { to, contents }
                    if to.ends_with("eee-xen-xen.cfg") =>
                {
                    Some(contents.clone())
                }
                _ => None,
            })
            .expect("a xen.cfg");

        assert_eq!(
            String::from_utf8(written).expect("utf8"),
            "default=nixos1\n\n[nixos1]\noptions=dom0_mem=4G ucode=scan\n\
             kernel=bbb-linux-Image init=/nix/store/aaa-finix-system/init console=ttyAMA0 quiet\n\
             ramdisk=ccc-initrd-initrd\n"
        );
    }

    /// Without a multiboot binary on disk there is nothing to boot, so the
    /// entry is listed but carries no protocol at all.
    #[test]
    fn a_xen_entry_with_no_multiboot_binary_carries_no_protocol() {
        let fixture = Fixture::new();
        let extension = xen(&fixture, false, false);
        fixture.generation(&boot_json_with(&fixture, "", &extension));

        let entries = fixture.render(false);

        assert!(
            entries.contains("//Generation 1 with Xen 4.19\n"),
            "{entries}"
        );
        assert!(!entries.contains("protocol: multiboot"), "{entries}");
        assert!(!entries.contains("protocol: efi"), "{entries}");
    }

    /// Rendering asks for the kernel and initrd but must not copy them.
    #[test]
    fn plans_the_copies_without_making_them() {
        let fixture = Fixture::new();
        fixture.generation(&boot_json(&fixture, ""));

        let mut plan = fixture.plan(false);
        fixture.render_with(&mut plan, false);

        assert_eq!(plan.actions().len(), 2);
        assert!(!fixture.dir.path().join("boot/limine").exists());
    }
}
