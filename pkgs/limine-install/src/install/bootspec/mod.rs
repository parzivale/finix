//! Parsing of a generation's `boot.json`: the bootspec document, its
//! specialisations and the Xen extension, flattened into one value.

#[expect(
    clippy::module_inception,
    reason = "the flattened bootspec is the module's subject"
)]
mod bootspec;
mod raw;

pub(crate) use bootspec::*;
