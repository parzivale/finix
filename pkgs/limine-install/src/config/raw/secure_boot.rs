use crate::config::{KeyPolicy, SecureBoot};
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// The module's `secureBoot` submodule.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RawSecureBoot {
    pub(super) enable: bool,
    auto_generate_keys: bool,
    auto_enroll_keys: RawAutoEnrollKeys,
    sbctl: PathBuf,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawAutoEnrollKeys {
    enable: bool,
    extra_args: Vec<String>,
}

/// Collapses four flags into the three states the script actually branches on
/// (`limine-install.py:516-550`): off; on with keys that must already exist;
/// on with key generation, which is the only path that can enrol.
pub(super) fn resolve(r: &RawSecureBoot, fwupd: Option<&Path>) -> SecureBoot {
    if !r.enable {
        return SecureBoot::Disabled;
    }

    let keys = if r.auto_generate_keys {
        KeyPolicy::Generate {
            enroll: r
                .auto_enroll_keys
                .enable
                .then(|| r.auto_enroll_keys.extra_args.clone()),
        }
    } else {
        KeyPolicy::Require
    };

    SecureBoot::Enabled {
        sbctl: r.sbctl.join("bin/sbctl"),
        keys,
        fwupd: fwupd.map(Path::to_path_buf),
    }
}
