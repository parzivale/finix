use super::error::{InstallError, ReadSnafu};
use snafu::ResultExt as _;
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Where nix keeps the system profile and its generations.
const SYSTEM_PROFILES: &str = "/nix/var/nix/profiles";

/// The profile directory the generations are read out of. A value rather than
/// a constant so that tests can point it at a fixture tree.
pub(crate) struct Profiles {
    root: PathBuf,
}

impl Profiles {
    pub(crate) fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
        }
    }

    pub(crate) fn system() -> Self {
        Self::new(Path::new(SYSTEM_PROFILES))
    }

    /// The symlink nix keeps for one generation of a profile.
    pub(crate) fn generation_path(&self, profile: &str, generation: u32) -> PathBuf {
        self.dir(profile)
            .join(format!("{profile}-{generation}-link"))
    }

    /// Every non-system profile, found by ignoring the generation symlinks.
    pub(crate) fn list(&self) -> Result<Vec<String>, InstallError> {
        let dir = self.root.join("system-profiles");

        if !dir.is_dir() {
            return Ok(Vec::new());
        }

        let mut profiles: Vec<String> = names(&dir)?
            .into_iter()
            .filter(|name| !name.ends_with("-link"))
            .collect();

        profiles.sort();
        Ok(profiles)
    }

    /// A profile's generation numbers, oldest first, trimmed to the newest
    /// `max`.
    ///
    /// These are exactly the `<profile>-<n>-link` symlinks nix keeps beside
    /// the profile, which is all `nix-env --list-generations` would read for
    /// us.
    pub(crate) fn generations(
        &self,
        profile: &str,
        max: Option<u32>,
    ) -> Result<Vec<u32>, InstallError> {
        let prefix = format!("{profile}-");

        let mut generations: Vec<u32> = names(&self.dir(profile))?
            .iter()
            .filter_map(|name| {
                name.strip_prefix(&prefix)?
                    .strip_suffix("-link")?
                    .parse()
                    .ok()
            })
            .collect();

        generations.sort_unstable();

        if let Some(max) = max {
            let keep = generations.len().saturating_sub(max as usize);
            generations.drain(..keep);
        }

        Ok(generations)
    }

    /// The system profile sits at the top; everything else under
    /// `system-profiles`.
    fn dir(&self, profile: &str) -> PathBuf {
        if profile == "system" {
            self.root.clone()
        } else {
            self.root.join("system-profiles")
        }
    }
}

fn names(dir: &Path) -> Result<Vec<String>, InstallError> {
    let mut names = Vec::new();

    for entry in fs::read_dir(dir).context(ReadSnafu { path: dir })? {
        let name = entry.context(ReadSnafu { path: dir })?.file_name();
        names.push(name.to_string_lossy().into_owned());
    }

    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::Profiles;
    use std::fs;
    use tempfile::TempDir;

    fn fixture(links: &[&str]) -> TempDir {
        let dir = TempDir::new().expect("temp dir");

        for link in links {
            let path = dir.path().join(link);
            fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
            fs::write(&path, "").expect("write");
        }

        dir
    }

    #[test]
    fn reads_generations_out_of_the_symlink_names() {
        let dir = fixture(&["system-1-link", "system-10-link", "system-2-link"]);

        assert_eq!(
            Profiles::new(dir.path())
                .generations("system", None)
                .unwrap(),
            [1, 2, 10]
        );
    }

    /// `system`, `system-profiles` and anything else beside them are not
    /// generations.
    #[test]
    fn ignores_everything_that_is_not_a_generation() {
        let dir = fixture(&[
            "system-1-link",
            "system",
            "system-profiles/test-1-link",
            "per-user/root/channels",
        ]);

        assert_eq!(
            Profiles::new(dir.path())
                .generations("system", None)
                .unwrap(),
            [1]
        );
    }

    #[test]
    fn keeps_only_the_newest_max_generations() {
        let dir = fixture(&["system-1-link", "system-2-link", "system-3-link"]);
        let profiles = Profiles::new(dir.path());

        assert_eq!(profiles.generations("system", Some(2)).unwrap(), [2, 3]);
        assert_eq!(profiles.generations("system", Some(9)).unwrap(), [1, 2, 3]);
    }

    #[test]
    fn finds_non_system_profiles_and_their_generations() {
        let dir = fixture(&[
            "system-1-link",
            "system-profiles/test",
            "system-profiles/test-1-link",
            "system-profiles/test-2-link",
        ]);
        let profiles = Profiles::new(dir.path());

        assert_eq!(profiles.list().unwrap(), ["test"]);
        assert_eq!(profiles.generations("test", None).unwrap(), [1, 2]);
    }

    #[test]
    fn a_system_without_other_profiles_lists_none() {
        let dir = fixture(&["system-1-link"]);

        assert!(Profiles::new(dir.path()).list().unwrap().is_empty());
    }

    #[test]
    fn generation_paths_are_where_nix_puts_them() {
        let dir = fixture(&[]);
        let profiles = Profiles::new(dir.path());

        assert_eq!(
            profiles.generation_path("system", 7),
            dir.path().join("system-7-link")
        );
        assert_eq!(
            profiles.generation_path("test", 7),
            dir.path().join("system-profiles/test-7-link")
        );
    }
}
