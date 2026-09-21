use super::error::{InstallError, NoSecureBootKeysSnafu, ReadSnafu};
use crate::{
    config::{KeyPolicy, SecureBoot},
    util::cmd,
};
use snafu::{ResultExt as _, ensure};
use std::{fs, io, path::Path, process::Command};

/// Where sbctl keeps the keys it generates. Passed in rather than reached for
/// directly, so that tests can decide whether keys already exist.
pub(crate) const STATE: &str = "/var/lib/sbctl";

/// Fail before we touch the boot filesystem if the keys we were told to use do
/// not exist.
pub(crate) fn check(secure_boot: &SecureBoot, state: &Path) -> Result<(), InstallError> {
    let SecureBoot::Enabled {
        keys: KeyPolicy::Require,
        ..
    } = secure_boot
    else {
        return Ok(());
    };

    ensure!(state.exists(), NoSecureBootKeysSnafu);
    Ok(())
}

/// Sign the EFI binary we just installed, generating and enrolling keys first
/// if that is what the module asked for.
pub(crate) fn sign(
    secure_boot: &SecureBoot,
    binary: &Path,
    state: &Path,
) -> Result<(), InstallError> {
    let SecureBoot::Enabled { sbctl, keys, fwupd } = secure_boot else {
        return Ok(());
    };

    if !state.exists()
        && let KeyPolicy::Generate { enroll } = keys
    {
        println!("auto generating keys");
        cmd::run(Command::new(sbctl).arg("create-keys"))?.success()?;

        if let Some(extra) = enroll {
            cmd::run(Command::new(sbctl).arg("enroll-keys").args(extra))?.success()?;
        }
    }

    println!("signing limine...");
    cmd::run(Command::new(sbctl).arg("sign").arg(binary))?.success()?;

    for binary in fwupd
        .as_deref()
        .map(efi_binaries)
        .transpose()?
        .unwrap_or_default()
    {
        println!(
            "signing fwupd: {}",
            binary.file_name().unwrap_or_default().to_string_lossy()
        );
        cmd::run(Command::new(sbctl).arg("sign").arg(&binary))?.success()?;
    }

    Ok(())
}

fn efi_binaries(fwupd: &Path) -> Result<Vec<std::path::PathBuf>, InstallError> {
    let dir = fwupd.join("libexec/fwupd/efi");

    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).context(ReadSnafu { path: dir }),
    };

    let mut binaries = Vec::new();
    for entry in entries {
        let path = entry.context(ReadSnafu { path: &dir })?.path();

        if path.extension().is_some_and(|extension| extension == "efi") {
            binaries.push(path);
        }
    }

    binaries.sort();
    Ok(binaries)
}

#[cfg(test)]
mod tests {
    use super::{check, sign};
    use crate::config::{KeyPolicy, SecureBoot};
    use std::{fs, os::unix::fs::PermissionsExt as _, path::Path, path::PathBuf};
    use tempfile::TempDir;

    /// An sbctl that records how it was called instead of touching any keys.
    struct Fake {
        dir: TempDir,
    }

    impl Fake {
        fn new() -> Self {
            let fake = Self {
                dir: TempDir::new().expect("temp dir"),
            };

            let script = format!(
                "#!/bin/sh\necho \"$@\" >> {}\n",
                fake.calls_path().display()
            );

            fs::write(fake.sbctl(), script).expect("write");
            fs::set_permissions(fake.sbctl(), fs::Permissions::from_mode(0o755)).expect("chmod");

            fake
        }

        fn sbctl(&self) -> PathBuf {
            self.dir.path().join("sbctl")
        }

        fn calls_path(&self) -> PathBuf {
            self.dir.path().join("calls")
        }

        /// One line per invocation, in order.
        fn calls(&self) -> Vec<String> {
            fs::read_to_string(self.calls_path())
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        /// A state directory that does or does not already hold keys.
        fn state(&self, exists: bool) -> PathBuf {
            let state = self.dir.path().join("state");

            if exists {
                fs::create_dir_all(&state).expect("mkdir");
            }

            state
        }

        fn enabled(&self, keys: KeyPolicy, fwupd: Option<PathBuf>) -> SecureBoot {
            SecureBoot::Enabled {
                sbctl: self.sbctl(),
                keys,
                fwupd,
            }
        }

        /// An fwupd store path with EFI binaries in it, and a decoy.
        fn fwupd(&self) -> PathBuf {
            let fwupd = self.dir.path().join("fwupd");
            let efi = fwupd.join("libexec/fwupd/efi");

            fs::create_dir_all(&efi).expect("mkdir");
            fs::write(efi.join("fwupdx64.efi"), "").expect("write");
            fs::write(efi.join("fwupd.efi"), "").expect("write");
            fs::write(efi.join("notes.txt"), "").expect("write");

            fwupd
        }
    }

    #[test]
    fn disabled_secure_boot_does_nothing() {
        let fake = Fake::new();

        check(&SecureBoot::Disabled, &fake.state(false)).expect("no check");
        sign(
            &SecureBoot::Disabled,
            Path::new("/boot/x.efi"),
            &fake.state(false),
        )
        .expect("no signing");

        assert!(fake.calls().is_empty());
    }

    /// Keys we were told already exist, and do not: refuse before anything is
    /// written to the ESP.
    #[test]
    fn requiring_keys_fails_when_there_are_none() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(KeyPolicy::Require, None);

        let error = check(&secure_boot, &fake.state(false)).unwrap_err();
        assert!(error.to_string().contains("no sbctl secure boot keys"));

        check(&secure_boot, &fake.state(true)).expect("keys are there");
    }

    /// Generation is allowed to find nothing, so the check passes either way.
    #[test]
    fn generating_keys_never_fails_the_check() {
        let fake = Fake::new();
        let generate = fake.enabled(KeyPolicy::Generate { enroll: None }, None);

        check(&generate, &fake.state(false)).expect("will generate");
    }

    #[test]
    fn signs_without_generating_when_keys_are_already_there() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(KeyPolicy::Generate { enroll: None }, None);

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(true)).expect("sign");

        assert_eq!(fake.calls(), ["sign /boot/x.efi"]);
    }

    #[test]
    fn generates_keys_before_signing_when_there_are_none() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(KeyPolicy::Generate { enroll: None }, None);

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(false)).expect("sign");

        assert_eq!(fake.calls(), ["create-keys", "sign /boot/x.efi"]);
    }

    /// Enrolment only happens on the generation path, and carries the extra
    /// arguments the module set.
    #[test]
    fn enrols_generated_keys_with_the_configured_arguments() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(
            KeyPolicy::Generate {
                enroll: Some(vec![
                    "--microsoft".to_owned(),
                    "--firmware-builtin".to_owned(),
                ]),
            },
            None,
        );

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(false)).expect("sign");

        assert_eq!(
            fake.calls(),
            [
                "create-keys",
                "enroll-keys --microsoft --firmware-builtin",
                "sign /boot/x.efi",
            ]
        );
    }

    /// Keys that already exist are never re-enrolled.
    #[test]
    fn does_not_enrol_over_existing_keys() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(
            KeyPolicy::Generate {
                enroll: Some(vec!["--microsoft".to_owned()]),
            },
            None,
        );

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(true)).expect("sign");

        assert_eq!(fake.calls(), ["sign /boot/x.efi"]);
    }

    /// fwupd's own EFI binaries have to be signed too, or firmware updates
    /// stop working under secure boot. Only the .efi ones.
    #[test]
    fn signs_every_fwupd_efi_binary() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(KeyPolicy::Require, Some(fake.fwupd()));
        let fwupd = fake.fwupd();

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(true)).expect("sign");

        let efi = fwupd.join("libexec/fwupd/efi");
        assert_eq!(
            fake.calls(),
            [
                "sign /boot/x.efi".to_owned(),
                format!("sign {}", efi.join("fwupd.efi").display()),
                format!("sign {}", efi.join("fwupdx64.efi").display()),
            ]
        );
    }

    /// An fwupd without an EFI directory is not an error.
    #[test]
    fn tolerates_an_fwupd_with_no_efi_binaries() {
        let fake = Fake::new();
        let secure_boot = fake.enabled(KeyPolicy::Require, Some(fake.dir.path().join("absent")));

        sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(true)).expect("sign");

        assert_eq!(fake.calls(), ["sign /boot/x.efi"]);
    }

    /// A failing sbctl has to stop the install, not be shrugged off the way
    /// the python script did.
    #[test]
    fn a_failing_sbctl_fails_the_install() {
        let fake = Fake::new();
        fs::write(
            fake.sbctl(),
            "#!/bin/sh\necho 'sbctl: setup mode disabled' >&2\nexit 1\n",
        )
        .expect("write");
        fs::set_permissions(fake.sbctl(), fs::Permissions::from_mode(0o755)).expect("chmod");

        let secure_boot = fake.enabled(KeyPolicy::Require, None);
        let error = sign(&secure_boot, Path::new("/boot/x.efi"), &fake.state(true)).unwrap_err();

        assert!(error.to_string().contains("failed"), "{error}");
    }
}
