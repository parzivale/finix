use crate::install::error::InstallError;
use snafu::Snafu;
use std::path::PathBuf;

/// Anything that stops us before the install proper begins.
#[derive(Debug, Snafu)]
#[snafu(visibility(pub(crate)))]
pub(crate) enum Error {
    /// No config path was given on the command line.
    #[snafu(display("usage: limine-install <install-config.json>"))]
    Usage,
    /// The config file could not be opened.
    #[snafu(display("could not open {}", path.display()))]
    OpenConfig {
        source: std::io::Error,
        path: PathBuf,
    },
    /// The config file is not a valid install config.
    #[snafu(display("could not parse {}", path.display()))]
    ParseConfig {
        source: serde_json::Error,
        path: PathBuf,
    },
    /// The install itself failed.
    #[snafu(display("could not install limine"))]
    Install { source: InstallError },
}
