//! Installs the limine bootloader for the system generations that nix knows
//! about, from the JSON the activation script hands us.

mod config;
mod error;
mod install;
mod util;

use config::LimineInstallConfig;
use error::{Error, InstallSnafu, OpenConfigSnafu, ParseConfigSnafu, UsageSnafu};
use snafu::{OptionExt as _, ResultExt as _};
use std::{fs::File, io::BufReader, path::PathBuf};

#[snafu::report]
fn main() -> Result<(), Error> {
    let path = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .context(UsageSnafu)?;
    let file = File::open(&path).context(OpenConfigSnafu { path: path.clone() })?;
    let cfg: LimineInstallConfig =
        serde_json::from_reader(BufReader::new(file)).context(ParseConfigSnafu { path })?;

    let result = install::run(&cfg).context(InstallSnafu);

    if let Err(error) = install::sync(&cfg.mount_point) {
        eprintln!("warning: {error}");
    }

    result
}
