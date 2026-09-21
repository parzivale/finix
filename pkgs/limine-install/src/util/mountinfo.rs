use snafu::{OptionExt as _, ResultExt as _, Snafu};
use std::{
    fs,
    path::{Path, PathBuf},
};

const MOUNTINFO: &str = "/proc/self/mountinfo";

#[derive(Debug, Snafu)]
pub(crate) enum MountinfoError {
    #[snafu(display("could not read {}", path.display()))]
    Read {
        source: std::io::Error,
        path: PathBuf,
    },
    /// Nothing in mountinfo covers the path, which for an absolute path should
    /// not happen: `/` is always mounted.
    #[snafu(display("{} is not on a mounted filesystem", path.display()))]
    NotMounted { path: PathBuf },
}

/// The device backing the filesystem `path` sits on: the longest mount point
/// that is a prefix of it, most recent mount winning.
pub(crate) fn device_for(path: &Path) -> Result<PathBuf, MountinfoError> {
    let path = fs::canonicalize(path).context(ReadSnafu { path })?;
    let mountinfo = fs::read_to_string(MOUNTINFO).context(ReadSnafu { path: MOUNTINFO })?;

    let mut best: Option<(usize, PathBuf)> = None;

    for line in mountinfo.lines() {
        // the optional fields before it are variable in number, so the fixed
        // tail is only addressable from the separator onwards.
        let Some((mount, source)) = line.split_once(" - ") else {
            continue;
        };

        let Some(mount) = mount.split_whitespace().nth(4).map(unescape) else {
            continue;
        };

        let Some(source) = source.split_whitespace().nth(1).map(unescape) else {
            continue;
        };

        if path.starts_with(&mount) && best.as_ref().is_none_or(|(len, _)| mount.len() >= *len) {
            best = Some((mount.len(), PathBuf::from(source)));
        }
    }

    best.map(|(_, source)| source)
        .context(NotMountedSnafu { path })
}

/// mountinfo octal-escapes the characters that would otherwise split a field:
/// space, tab, newline and the backslash itself.
fn unescape(field: &str) -> String {
    let mut out = Vec::with_capacity(field.len());
    let mut bytes = field.bytes();

    while let Some(byte) = bytes.next() {
        if byte != b'\\' {
            out.push(byte);
            continue;
        }

        let escape: Vec<u8> = bytes.by_ref().take(3).collect();
        let decoded = std::str::from_utf8(&escape)
            .ok()
            .and_then(|octal| u8::from_str_radix(octal, 8).ok());

        if let Some(byte) = decoded {
            out.push(byte);
        } else {
            out.push(b'\\');
            out.extend_from_slice(&escape);
        }
    }

    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::unescape;

    #[test]
    fn leaves_ordinary_paths_alone() {
        assert_eq!(unescape("/boot/efi"), "/boot/efi");
    }

    #[test]
    fn decodes_the_four_escaped_characters() {
        assert_eq!(unescape(r"/mnt/my\040disk"), "/mnt/my disk");
        assert_eq!(unescape(r"/mnt/a\011b"), "/mnt/a\tb");
        assert_eq!(unescape(r"/mnt/a\012b"), "/mnt/a\nb");
        assert_eq!(unescape(r"/mnt/a\134b"), r"/mnt/a\b");
    }

    #[test]
    fn keeps_a_malformed_escape_verbatim() {
        assert_eq!(unescape(r"/mnt/a\09"), r"/mnt/a\09");
        assert_eq!(unescape(r"/mnt/a\zzz"), r"/mnt/a\zzz");
    }

    #[test]
    fn decodes_several_in_one_field() {
        assert_eq!(unescape(r"/a\040b\040c"), "/a b c");
    }
}
