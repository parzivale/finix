//! The `boot.json` nix writes, and its flattening into [`BootSpec`]. Each
//! decision the conversion makes lives in its own submodule; this file only
//! does the plumbing.

mod document;
mod xen;

use super::BootSpec;
use document::Document;
use serde::Deserialize;
use std::collections::BTreeMap;
use xen::RawXen;

#[derive(Deserialize)]
pub(super) struct Raw {
    #[serde(rename = "org.nixos.bootspec.v1")]
    document: Document,
    /// Absent on generations built before specialisations were written out.
    #[serde(rename = "org.nixos.specialisation.v1", default)]
    specialisations: BTreeMap<String, Self>,
    #[serde(rename = "org.xenproject.bootspec.v2")]
    xen: Option<RawXen>,
}

impl From<Raw> for BootSpec {
    fn from(r: Raw) -> Self {
        Self {
            init: r.document.init,
            kernel: r.document.kernel,
            kernel_params: r.document.kernel_params,
            label: r.document.label,
            toplevel: r.document.toplevel,
            initrd: r.document.initrd,
            initrd_secrets: r.document.initrd_secrets,
            specialisations: r
                .specialisations
                .into_iter()
                .map(|(name, spec)| (name, spec.into()))
                .collect(),
            xen: r.xen.and_then(xen::resolve),
        }
    }
}
