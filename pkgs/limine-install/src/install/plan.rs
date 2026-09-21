use super::error::{CopySnafu, CreateDirSnafu, InstallError, ReadSnafu, RemoveSnafu, WriteSnafu};
use crate::util::hash;
use snafu::ResultExt as _;
use std::{
    collections::BTreeSet,
    ffi::OsString,
    fs::{self, File},
    io::Write as _,
    path::{Path, PathBuf},
};

/// What the install intends to put on the boot filesystem.
///
/// Building a plan reads -- sources have to be hashed for their `boot():`
/// URIs -- but never writes, so rendering limine.conf cannot leave anything
/// behind. [`Plan::apply`] is the only thing here that touches the
/// destination.
pub(crate) struct Plan {
    install_dir: PathBuf,
    validate_checksums: bool,
    actions: Vec<Action>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Action {
    /// Make the destination match the source.
    Copy { from: PathBuf, to: PathBuf },
    /// Copy only if the destination is missing. Copied files are named after
    /// the store path they came from, so one that is already there is already
    /// the right bytes -- and kernels are big.
    CopyIfMissing { from: PathBuf, to: PathBuf },
    /// Write freshly generated contents.
    Write { to: PathBuf, contents: Vec<u8> },
}

impl Action {
    pub(crate) fn destination(&self) -> &Path {
        match self {
            Self::Copy { to, .. } | Self::CopyIfMissing { to, .. } | Self::Write { to, .. } => to,
        }
    }
}

impl Plan {
    pub(crate) fn new(install_dir: &Path, validate_checksums: bool) -> Self {
        Self {
            install_dir: install_dir.to_path_buf(),
            validate_checksums,
            actions: Vec::new(),
        }
    }

    pub(crate) fn install_dir(&self) -> &Path {
        &self.install_dir
    }

    #[cfg(test)]
    pub(crate) fn actions(&self) -> &[Action] {
        &self.actions
    }

    pub(crate) fn copy(&mut self, from: &Path, to: &Path) {
        self.actions.push(Action::Copy {
            from: from.to_path_buf(),
            to: to.to_path_buf(),
        });
    }

    /// For files whose name already carries their store hash, so one that is
    /// there is the right one.
    pub(crate) fn copy_if_missing(&mut self, from: &Path, to: &Path) {
        self.actions.push(Action::CopyIfMissing {
            from: from.to_path_buf(),
            to: to.to_path_buf(),
        });
    }

    pub(crate) fn write(&mut self, to: &Path, contents: impl Into<Vec<u8>>) {
        self.actions.push(Action::Write {
            to: to.to_path_buf(),
            contents: contents.into(),
        });
    }

    /// Where `path` lands under `target`, named after the store path it came
    /// from so that two generations never collide.
    pub(crate) fn dest_path(&self, path: &Path, target: &str) -> PathBuf {
        self.install_dir.join(target).join(dest_file(path))
    }

    /// Ask for `path` under `target`, and return the URI limine.conf refers to
    /// it by.
    pub(crate) fn copied_uri(&mut self, path: &Path, target: &str) -> Result<String, InstallError> {
        let to = self.dest_path(path, target);

        self.copy_if_missing(path, &to);

        let mut uri = format!("boot():{}", uri_path(path, target).display());

        if self.validate_checksums {
            uri.push('#');
            uri.push_str(&hash::blake2b_file(path).context(ReadSnafu { path })?);
        }

        Ok(uri)
    }

    /// Everything the plan asks for, then everything under the install
    /// directory that it does not.
    pub(crate) fn apply(&self) -> Result<(), InstallError> {
        for action in &self.actions {
            match action {
                Action::Copy { from, to } => copy(from, to)?,
                Action::CopyIfMissing { from, to } => {
                    if !to.exists() {
                        copy(from, to)?;
                    }
                }
                Action::Write { to, contents } => write(to, contents)?,
            }
        }

        self.prune()
    }

    fn prune(&self) -> Result<(), InstallError> {
        let wanted: BTreeSet<&Path> = self.actions.iter().map(Action::destination).collect();

        let mut present = Vec::new();
        collect(&self.install_dir, &mut present)?;

        for path in present
            .iter()
            .filter(|path| !wanted.contains(path.as_path()))
        {
            fs::remove_file(path).context(RemoveSnafu { path })?;
        }

        // a generation that has gone away takes its xen directory with it
        remove_empty_dirs(&self.install_dir)
    }
}

/// The `boot():`-relative path of a file copied into `target`.
fn uri_path(path: &Path, target: &str) -> PathBuf {
    Path::new("/limine").join(target).join(dest_file(path))
}

fn dest_file(path: &Path) -> OsString {
    let package = path.parent().and_then(Path::file_name).unwrap_or_default();

    let mut name = package.to_os_string();
    name.push("-");
    name.push(path.file_name().unwrap_or_default());
    name
}

fn with_tmp_suffix(path: &Path) -> PathBuf {
    let mut tmp = path.to_path_buf().into_os_string();
    tmp.push(".tmp");
    tmp.into()
}

fn copy(from: &Path, to: &Path) -> Result<(), InstallError> {
    create_parent(to)?;

    let tmp = with_tmp_suffix(to);
    fs::copy(from, &tmp).context(CopySnafu { from, to: &tmp })?;
    fs::rename(&tmp, to).context(CopySnafu { from: &tmp, to })
}

/// Replace a file, making sure it has actually hit the disk before the old
/// contents go away.
fn write(to: &Path, contents: &[u8]) -> Result<(), InstallError> {
    create_parent(to)?;

    let tmp = with_tmp_suffix(to);
    let mut file = File::create(&tmp).context(WriteSnafu { path: &tmp })?;
    file.write_all(contents)
        .and_then(|()| file.sync_all())
        .context(WriteSnafu { path: &tmp })?;

    fs::rename(&tmp, to).context(WriteSnafu { path: to })
}

fn create_parent(path: &Path) -> Result<(), InstallError> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };

    if !parent.exists() {
        fs::create_dir_all(parent).context(CreateDirSnafu { path: parent })?;
    }

    Ok(())
}

fn collect(dir: &Path, files: &mut Vec<PathBuf>) -> Result<(), InstallError> {
    if !dir.exists() {
        return Ok(());
    }

    for entry in fs::read_dir(dir).context(ReadSnafu { path: dir })? {
        let path = entry.context(ReadSnafu { path: dir })?.path();

        if path.is_dir() {
            collect(&path, files)?;
        } else {
            files.push(path);
        }
    }

    Ok(())
}

/// Depth first, so that a directory emptied by its children goes too.
fn remove_empty_dirs(dir: &Path) -> Result<(), InstallError> {
    if !dir.exists() {
        return Ok(());
    }

    for entry in fs::read_dir(dir).context(ReadSnafu { path: dir })? {
        let path = entry.context(ReadSnafu { path: dir })?.path();

        if path.is_dir() {
            remove_empty_dirs(&path)?;

            if fs::read_dir(&path)
                .context(ReadSnafu { path: &path })?
                .next()
                .is_none()
            {
                fs::remove_dir(&path).context(RemoveSnafu { path })?;
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Action, Plan, dest_file, uri_path};
    use std::path::{Path, PathBuf};

    const KERNEL: &str = "/nix/store/abcdef-linux-6.18.50/Image";

    fn plan() -> Plan {
        Plan::new(Path::new("/boot/limine"), false)
    }

    /// The store hash has to survive into the name, or two generations sharing
    /// a filename would overwrite each other on the ESP.
    #[test]
    fn names_copies_after_the_store_path_they_came_from() {
        assert_eq!(dest_file(Path::new(KERNEL)), "abcdef-linux-6.18.50-Image");
    }

    #[test]
    fn puts_copies_under_their_target_directory() {
        assert_eq!(
            plan().dest_path(Path::new(KERNEL), "kernels"),
            PathBuf::from("/boot/limine/kernels/abcdef-linux-6.18.50-Image")
        );
    }

    /// limine resolves `boot():` against the volume it was loaded from, so the
    /// URI is rooted at /limine regardless of where the ESP is mounted.
    #[test]
    fn uris_are_relative_to_the_boot_volume() {
        assert_eq!(
            uri_path(Path::new(KERNEL), "kernels"),
            PathBuf::from("/limine/kernels/abcdef-linux-6.18.50-Image")
        );
    }

    #[test]
    fn an_empty_target_puts_the_file_at_the_top() {
        assert_eq!(
            uri_path(Path::new(KERNEL), ""),
            PathBuf::from("/limine/abcdef-linux-6.18.50-Image")
        );
    }

    /// Building the plan must not touch the destination.
    #[test]
    fn records_what_it_would_do_without_doing_it() {
        let mut plan = plan();
        plan.copy(
            Path::new("/nix/store/x-limine/BOOTAA64.EFI"),
            Path::new("/boot/efi/boot/BOOTAA64.EFI"),
        );
        plan.write(Path::new("/boot/limine/limine.conf"), "timeout: 5\n");

        assert_eq!(
            plan.actions(),
            [
                Action::Copy {
                    from: PathBuf::from("/nix/store/x-limine/BOOTAA64.EFI"),
                    to: PathBuf::from("/boot/efi/boot/BOOTAA64.EFI"),
                },
                Action::Write {
                    to: PathBuf::from("/boot/limine/limine.conf"),
                    contents: b"timeout: 5\n".to_vec(),
                },
            ]
        );

        assert!(!Path::new("/boot/limine/limine.conf").exists());
    }

    /// Kernels are content-addressed by name, so re-copying one is only ever
    /// wasted I/O -- and they are the big files.
    #[test]
    fn asks_for_kernels_only_if_they_are_missing() {
        let mut plan = plan();
        let uri = plan.copied_uri(Path::new(KERNEL), "kernels").unwrap();

        assert_eq!(uri, "boot():/limine/kernels/abcdef-linux-6.18.50-Image");
        assert!(matches!(plan.actions(), [Action::CopyIfMissing { .. }]));
    }

    mod apply {
        use super::super::Plan;
        use std::{
            fs,
            path::{Path, PathBuf},
        };
        use tempfile::TempDir;

        struct Fixture {
            dir: TempDir,
        }

        impl Fixture {
            fn new() -> Self {
                Self {
                    dir: TempDir::new().expect("temp dir"),
                }
            }

            fn install_dir(&self) -> PathBuf {
                self.dir.path().join("boot/limine")
            }

            fn plan(&self) -> Plan {
                Plan::new(&self.install_dir(), false)
            }

            fn source(&self, name: &str, contents: &str) -> PathBuf {
                let path = self.dir.path().join(name);
                fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
                fs::write(&path, contents).expect("write");
                path
            }

            /// A file already sitting under the install directory.
            fn existing(&self, name: &str, contents: &str) -> PathBuf {
                let path = self.install_dir().join(name);
                fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
                fs::write(&path, contents).expect("write");
                path
            }
        }

        fn read(path: &Path) -> String {
            fs::read_to_string(path).expect("read")
        }

        #[test]
        fn creates_the_directories_it_needs() {
            let fixture = Fixture::new();
            let source = fixture.source("store/kernel", "bytes");
            let dest = fixture.install_dir().join("kernels/deep/kernel");

            let mut plan = fixture.plan();
            plan.copy(&source, &dest);
            plan.apply().expect("apply");

            assert_eq!(read(&dest), "bytes");
        }

        #[test]
        fn a_copy_replaces_whatever_was_there() {
            let fixture = Fixture::new();
            let source = fixture.source("store/efi", "new");
            let dest = fixture.existing("BOOTAA64.EFI", "old");

            let mut plan = fixture.plan();
            plan.copy(&source, &dest);
            plan.apply().expect("apply");

            assert_eq!(read(&dest), "new");
        }

        /// The whole point of the distinction: a kernel already on the ESP is
        /// the same kernel, and copying 60M again is pure waste.
        #[test]
        fn copy_if_missing_leaves_an_existing_file_alone() {
            let fixture = Fixture::new();
            let source = fixture.source("store/kernel", "new");
            let dest = fixture.existing("kernels/kernel", "old");

            let mut plan = fixture.plan();
            plan.copy_if_missing(&source, &dest);
            plan.apply().expect("apply");

            assert_eq!(read(&dest), "old");
        }

        #[test]
        fn copy_if_missing_still_copies_when_it_is_not_there() {
            let fixture = Fixture::new();
            let source = fixture.source("store/kernel", "new");
            let dest = fixture.install_dir().join("kernels/kernel");

            let mut plan = fixture.plan();
            plan.copy_if_missing(&source, &dest);
            plan.apply().expect("apply");

            assert_eq!(read(&dest), "new");
        }

        #[test]
        fn writes_generated_contents() {
            let fixture = Fixture::new();
            let dest = fixture.install_dir().join("limine.conf");

            let mut plan = fixture.plan();
            plan.write(&dest, "timeout: 5\n");
            plan.apply().expect("apply");

            assert_eq!(read(&dest), "timeout: 5\n");
        }

        /// Anything under the install directory the plan did not ask for
        /// belongs to a generation that has gone away.
        #[test]
        fn prunes_what_the_plan_did_not_ask_for() {
            let fixture = Fixture::new();
            let source = fixture.source("store/kernel", "bytes");
            let kept = fixture.install_dir().join("kernels/kernel");
            let stale = fixture.existing("kernels/old-kernel", "stale");

            let mut plan = fixture.plan();
            plan.copy(&source, &kept);
            plan.apply().expect("apply");

            assert!(kept.exists());
            assert!(!stale.exists());
        }

        /// The EFI binary and additionalFiles land outside the install
        /// directory, and must survive a prune that never surveyed them.
        #[test]
        fn never_touches_anything_outside_the_install_directory() {
            let fixture = Fixture::new();
            let source = fixture.source("store/efi", "bytes");
            let outside = fixture.dir.path().join("boot/efi/boot/BOOTAA64.EFI");
            let bystander = fixture.source("boot/unrelated", "keep me");

            let mut plan = fixture.plan();
            plan.copy(&source, &outside);
            plan.apply().expect("apply");

            assert!(outside.exists());
            assert!(bystander.exists());
        }

        /// A generation that has gone away takes its xen directory with it.
        #[test]
        fn prunes_directories_left_empty() {
            let fixture = Fixture::new();
            fixture.existing("xen/220/xen.cfg", "stale");

            fixture.plan().apply().expect("apply");

            assert!(!fixture.install_dir().join("xen/220").exists());
            assert!(!fixture.install_dir().join("xen").exists());
        }

        /// Applying the same plan twice has to leave the same result.
        #[test]
        fn is_idempotent() {
            let fixture = Fixture::new();
            let source = fixture.source("store/kernel", "bytes");
            let dest = fixture.install_dir().join("kernels/kernel");

            let mut plan = fixture.plan();
            plan.copy_if_missing(&source, &dest);

            plan.apply().expect("first");
            plan.apply().expect("second");

            assert_eq!(read(&dest), "bytes");
        }
    }
}
