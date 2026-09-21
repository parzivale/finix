use serde::Deserialize;
use std::path::PathBuf;

/// `org.nixos.bootspec.v1`, narrowed to the fields limine.conf needs.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Document {
    pub(super) init: PathBuf,
    pub(super) kernel: PathBuf,
    pub(super) kernel_params: Vec<String>,
    pub(super) label: String,
    pub(super) toplevel: PathBuf,
    pub(super) initrd: Option<PathBuf>,
    pub(super) initrd_secrets: Option<PathBuf>,
}
