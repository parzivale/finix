//! Parsing and validation of the JSON install config handed to us by the
//! module's activation script.

#[expect(
    clippy::module_inception,
    reason = "the resolved config is the module's subject"
)]
mod config;
pub(crate) mod error;
mod raw;
mod settings;

pub(crate) use config::*;
pub(crate) use settings::Setting;
