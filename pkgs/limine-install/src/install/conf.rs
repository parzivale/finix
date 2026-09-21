use super::{
    bootspec::BootSpec,
    entries,
    error::{InstallError, NoGenerationsSnafu},
    plan::Plan,
    profiles::Profiles,
};
use crate::config::{LimineInstallConfig, Setting};
use snafu::OptionExt as _;
use std::path::Path;

/// limine picks the entry to boot by index, and the first lines of the menu are
/// ours.
const DEFAULT_ENTRY: &str = "default_entry";

/// The one setting whose value is a path we have to put on the boot filesystem
/// ourselves.
const WALLPAPER: &str = "wallpaper";

/// The whole of limine.conf: the module's settings, then a group per profile
/// with its generations newest first, then the user's extra entries.
pub(crate) fn generate(
    plan: &mut Plan,
    cfg: &LimineInstallConfig,
    profiles: &Profiles,
) -> Result<String, InstallError> {
    let system = profiles.generations("system", cfg.max_generations)?;
    let latest = *system.last().context(NoGenerationsSnafu)?;

    let mut all = vec![("system".to_owned(), system)];
    for profile in profiles.list()? {
        let generations = profiles.generations(&profile, cfg.max_generations)?;
        all.push((profile, generations));
    }

    let mut out = settings(plan, cfg)?;

    if !cfg.settings.contains_key(DEFAULT_ENTRY) {
        out.push(format!(
            "{DEFAULT_ENTRY}: {}\n",
            default_entry(profiles, latest)?
        ));
    }

    out.push("\n# NixOS boot entries start here\n".to_owned());

    let efi_support = cfg.efi_support();

    for (profile, generations) in &all {
        let group = if profile == "system" {
            "default profile".to_owned()
        } else {
            format!("profile '{profile}'")
        };

        out.push(format!("/+NixOS {group}\n"));

        for (position, generation) in generations.iter().rev().enumerate() {
            out.push(entries::generate(
                plan,
                profiles,
                profile,
                *generation,
                efi_support,
                position == 0,
            )?);
        }
    }

    out.push("\n# NixOS boot entries end here\n\n".to_owned());
    out.push(cfg.extra_entries.clone());

    Ok(out.concat().trim().to_owned())
}

/// The index of the newest generation's own entry, which is one deeper when it
/// has specialisations to hold.
fn default_entry(profiles: &Profiles, latest: u32) -> Result<u32, InstallError> {
    let link = profiles.generation_path("system", latest);
    let spec = BootSpec::load(&link.join("boot.json"))?;

    // one deeper when the generation is a submenu; see BootSpec::has_specialisations
    Ok(if spec.has_specialisations() { 3 } else { 2 })
}

fn settings(plan: &mut Plan, cfg: &LimineInstallConfig) -> Result<Vec<String>, InstallError> {
    let mut out = Vec::new();

    for (key, setting) in &cfg.settings {
        let values = match setting {
            Setting::One(value) => std::slice::from_ref(value),
            Setting::Many(values) => values.as_slice(),
        };

        for value in values {
            if key == WALLPAPER
                && let Some(path) = value.as_str()
            {
                let uri = plan.copied_uri(Path::new(path), "wallpapers")?;
                out.push(format!("{key}: {uri}\n"));
            } else if let Some(value) = value.value() {
                out.push(format!("{key}: {value}\n"));
            }
        }
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::generate;
    use crate::{
        config::LimineInstallConfig,
        install::{plan::Plan, profiles::Profiles},
    };
    use serde_json::{Value, json};
    use std::{fs, path::PathBuf};
    use tempfile::TempDir;

    struct Fixture {
        dir: TempDir,
    }

    impl Fixture {
        /// A profile tree with one generation per number in `generations`,
        /// under `profile`.
        fn new(profile: &str, generations: &[u32]) -> Self {
            let fixture = Self {
                dir: TempDir::new().expect("temp dir"),
            };

            for generation in generations {
                fixture.generation(profile, *generation, "");
            }

            fixture
        }

        fn generation(&self, profile: &str, generation: u32, specialisations: &str) {
            let store = self.dir.path().join("store");
            let toplevel = self.dir.path().join(format!("{profile}-{generation}"));
            fs::create_dir_all(&toplevel).expect("mkdir");

            let boot_json = format!(
                r#"{{
                  "org.nixos.bootspec.v1": {{
                    "init": "/nix/store/aaa-{profile}-{generation}/init",
                    "kernel": "{}/bbb-linux/Image",
                    "kernelParams": ["quiet"],
                    "label": "finix {generation}",
                    "system": "aarch64-linux",
                    "toplevel": "/nix/store/aaa-{profile}-{generation}"
                  }},
                  "org.nixos.specialisation.v1": {{{specialisations}}}
                }}"#,
                store.display()
            );

            fs::write(toplevel.join("boot.json"), boot_json).expect("boot.json");

            let dir = if profile == "system" {
                self.profiles()
            } else {
                self.profiles().join("system-profiles")
            };

            fs::create_dir_all(&dir).expect("mkdir");

            let link = dir.join(format!("{profile}-{generation}-link"));
            std::os::unix::fs::symlink(&toplevel, &link).expect("symlink");

            // nix keeps the profile itself beside its generations, and that is
            // what a non-system profile is discovered by
            let current = dir.join(profile);
            let _ = fs::remove_file(&current);
            std::os::unix::fs::symlink(&link, &current).expect("symlink");
        }

        fn profiles(&self) -> PathBuf {
            self.dir.path().join("profiles")
        }

        fn config(&self, overrides: Value) -> LimineInstallConfig {
            let mut json = json!({
                "additionalFiles": {},
                "biosDevice": "nodev",
                "biosSupport": false,
                "canTouchEfiVariables": false,
                "efiMountPoint": self.dir.path().join("boot"),
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
                "validateChecksums": false
            });

            let Value::Object(overrides) = overrides else {
                panic!("overrides must be an object");
            };

            for (key, value) in overrides {
                json[key] = value;
            }

            serde_json::from_value(json).expect("a valid config")
        }

        fn render(&self, overrides: Value) -> String {
            let cfg = self.config(overrides);
            let mut plan = Plan::new(&cfg.install_dir, cfg.validate_checksums);

            generate(&mut plan, &cfg, &Profiles::new(&self.profiles())).expect("limine.conf")
        }
    }

    /// Drop the entry bodies, which entries.rs covers, and keep the frame.
    fn skeleton(conf: &str) -> Vec<&str> {
        conf.lines()
            .filter(|line| {
                line.is_empty()
                    || line.starts_with('/')
                    || line.starts_with('#')
                    || line.starts_with("default_entry")
            })
            .collect()
    }

    #[test]
    fn frames_the_entries_with_the_markers_the_module_documents() {
        let fixture = Fixture::new("system", &[1]);

        assert_eq!(
            skeleton(&fixture.render(json!({}))),
            [
                "default_entry: 2",
                "",
                "# NixOS boot entries start here",
                "/+NixOS default profile",
                "//Generation 1",
                "",
                "# NixOS boot entries end here",
            ]
        );
    }

    /// Newest first, and only the newest is expanded.
    #[test]
    fn lists_generations_newest_first() {
        let fixture = Fixture::new("system", &[1, 2, 3]);
        let conf = fixture.render(json!({}));

        let generations: Vec<&str> = conf.lines().filter(|line| line.starts_with("//")).collect();

        assert_eq!(
            generations,
            ["//Generation 3", "//Generation 2", "//Generation 1"]
        );
    }

    #[test]
    fn honours_max_generations() {
        let fixture = Fixture::new("system", &[1, 2, 3]);
        let conf = fixture.render(json!({"maxGenerations": 2}));

        assert!(conf.contains("//Generation 3"));
        assert!(conf.contains("//Generation 2"));
        assert!(!conf.contains("//Generation 1"), "{conf}");
    }

    #[test]
    fn gives_every_profile_its_own_group() {
        let fixture = Fixture::new("system", &[1]);
        fixture.generation("test", 1, "");

        let conf = fixture.render(json!({}));

        assert!(conf.contains("/+NixOS default profile"));
        assert!(conf.contains("/+NixOS profile 'test'"), "{conf}");
    }

    #[test]
    fn renders_settings_the_way_limine_spells_them() {
        let fixture = Fixture::new("system", &[1]);
        let conf = fixture.render(json!({
            "settings": {"graphics": true, "editor_enabled": false, "timeout": "no", "backdrop": "2F302F"}
        }));

        // key order is the module's, which nix emits sorted
        let settings: Vec<&str> = conf.lines().take_while(|line| !line.is_empty()).collect();

        assert_eq!(
            settings,
            [
                "backdrop: 2F302F",
                "editor_enabled: no",
                "graphics: yes",
                "timeout: no",
                "default_entry: 2",
            ]
        );
    }

    /// A list setting becomes one line per element.
    #[test]
    fn repeats_a_key_for_each_value_in_a_list() {
        let fixture = Fixture::new("system", &[1]);
        let conf = fixture.render(json!({"settings": {"module_path": ["a", "b"]}}));

        assert!(conf.contains("module_path: a\nmodule_path: b\n"), "{conf}");
    }

    /// Wallpapers are the one setting naming a file we have to put on the ESP.
    #[test]
    fn copies_wallpapers_and_refers_to_them_by_uri() {
        let fixture = Fixture::new("system", &[1]);
        let wallpaper = fixture.dir.path().join("store/ddd-art/bg.png");

        let cfg = fixture.config(json!({"settings": {"wallpaper": [wallpaper]}}));
        let mut plan = Plan::new(&cfg.install_dir, cfg.validate_checksums);
        let conf = generate(&mut plan, &cfg, &Profiles::new(&fixture.profiles())).expect("conf");

        assert!(
            conf.contains("wallpaper: boot():/limine/wallpapers/ddd-art-bg.png"),
            "{conf}"
        );
        assert!(
            plan.actions()
                .iter()
                .any(|action| action.destination().ends_with("wallpapers/ddd-art-bg.png")),
            "the wallpaper was never asked for"
        );
    }

    /// `default_entry` is injected only when the module has not set it, and
    /// points one deeper when the newest generation is a submenu.
    #[test]
    fn picks_a_default_entry_that_matches_the_menu_depth() {
        let plain = Fixture::new("system", &[1]);
        assert!(plain.render(json!({})).contains("default_entry: 2"));

        let nested = Fixture::new("system", &[]);
        nested.generation(
            "system",
            1,
            &format!(
                r#""hardened": {{
                  "org.nixos.bootspec.v1": {{
                    "init": "/nix/store/ddd/init", "kernel": "{}/bbb-linux/Image",
                    "kernelParams": [], "label": "h", "system": "aarch64-linux",
                    "toplevel": "/nix/store/ddd"
                  }},
                  "org.nixos.specialisation.v1": {{}}
                }}"#,
                nested.dir.path().join("store").display()
            ),
        );
        assert!(nested.render(json!({})).contains("default_entry: 3"));
    }

    #[test]
    fn leaves_an_explicit_default_entry_alone() {
        let fixture = Fixture::new("system", &[1]);
        let conf = fixture.render(json!({"settings": {"default_entry": 7}}));

        assert!(conf.contains("default_entry: 7"), "{conf}");
        assert_eq!(conf.matches("default_entry").count(), 1, "{conf}");
    }

    #[test]
    fn appends_extra_entries_after_the_generated_ones() {
        let fixture = Fixture::new("system", &[1]);
        let conf = fixture.render(json!({"extraEntries": "/memtest\n  protocol: chainload\n"}));

        let (_, tail) = conf
            .split_once("# NixOS boot entries end here")
            .expect("marker");
        assert_eq!(tail.trim(), "/memtest\n  protocol: chainload");
    }

    /// Nothing may be written while the config is being assembled.
    #[test]
    fn writes_nothing_while_rendering() {
        let fixture = Fixture::new("system", &[1]);
        fixture.render(json!({}));

        assert!(!fixture.dir.path().join("boot").exists());
    }
}
