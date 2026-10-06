//! What each backend supplied, handed over as one file.
//!
//! Everything in here is a *command line*, not something this program does itself. That is the
//! whole design of `providers/services/ctl.nix` and the port does not change it: one front-end,
//! seven backends, each of which fills in `ctl.status`, `switch.activate`, `switch.deactivate`,
//! `user.ctl`, `user.status` and `shutdownCommands` in its own vocabulary. This decides *which*
//! of them to reach for, and then reaches for it.
//!
//! So a backend is added without touching this crate, which is the property worth keeping: the
//! alternative is a tool that has to learn each init, which is the situation that existed before
//! `initctl` and is why it exists.

use crate::resolve::Entry;
use serde::Deserialize;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
pub struct Manifest {
    /// Every command here is typed `str` in the contract - a command line, which may carry
    /// arguments - so something has to parse it, and it is the same bash that interpolated these
    /// inline when this was a shell script.
    pub shell: String,

    /// which tree owns each name, decided at build time.
    ///
    /// The names are known then, so a lookup answers "who owns `mako`" without opening a
    /// conversation with every supervisor on the machine to find out.
    pub index: Vec<Entry>,

    pub system: System,

    #[serde(default)]
    pub users: BTreeMap<String, UserTree>,

    #[serde(default)]
    pub shutdown: Shutdown,
}

#[derive(Debug, Deserialize)]
pub struct System {
    /// reports every unit as `name<TAB>state`, in the contract's vocabulary rather than the
    /// backend's own.
    pub status: String,

    /// both take unit names on stdin, one per line - that is `switch`'s interface and this is
    /// just another caller of it.
    pub activate: String,
    pub deactivate: String,
}

#[derive(Debug, Deserialize)]
pub struct UserTree {
    /// takes a subcommand and a unit name as arguments, as `dinitctl` does. Split on whitespace,
    /// which is what the shell did to it and what the contract's own comment describes.
    pub ctl: String,
    pub status: String,
}

#[derive(Debug, Default, Deserialize)]
pub struct Shutdown {
    #[serde(default)]
    pub reboot: Option<String>,
    #[serde(default)]
    pub poweroff: Option<String>,
    #[serde(default)]
    pub halt: Option<String>,
}

impl Manifest {
    pub fn load(path: &str) -> Result<Self, String> {
        let text =
            std::fs::read_to_string(path).map_err(|e| format!("reading manifest {path}: {e}"))?;
        serde_json::from_str(&text).map_err(|e| format!("parsing manifest {path}: {e}"))
    }
}
