use blake2::{Blake2b512, Digest as _};
use std::{fmt::Write as _, fs::File, io::Read as _, io::Result, path::Path};

/// The digest limine expects after the `#` of a `boot():` URI, and the one
/// `limine enroll-config` is handed.
pub(crate) fn blake2b(bytes: &[u8]) -> String {
    hex(Blake2b512::digest(bytes).as_slice())
}

/// Read in chunks: the files being hashed are kernels and initrds, and there
/// is one of each per generation.
pub(crate) fn blake2b_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Blake2b512::new();
    let mut buffer = vec![0; 64 * 1024];

    loop {
        let read = file.read(&mut buffer)?;

        if read == 0 {
            return Ok(hex(hasher.finalize().as_slice()));
        }

        hasher.update(&buffer[..read]);
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

#[cfg(test)]
mod tests {
    use super::{blake2b, blake2b_file};

    /// Vectors from `b2sum`, which is what limine's checksums have to agree
    /// with.
    #[test]
    fn matches_b2sum() {
        assert!(blake2b(b"").starts_with("786a02f742015903c6c6fd852552d272"));
        assert!(blake2b(b"abc").starts_with("ba80a53f981c4d0d6a2797b69f12f6e9"));
    }

    #[test]
    fn is_a_512_bit_digest_in_hex() {
        assert_eq!(blake2b(b"anything").len(), 128);
    }

    /// The chunked read has to produce the same digest as the one-shot.
    #[test]
    fn hashing_a_file_agrees_with_hashing_its_bytes() {
        let path = std::env::temp_dir().join(format!("limine-hash-{}", std::process::id()));
        let contents = vec![0xab; 200 * 1024];

        std::fs::write(&path, &contents).expect("write");
        let digest = blake2b_file(&path);
        std::fs::remove_file(&path).expect("remove");

        assert_eq!(digest.expect("digest"), blake2b(&contents));
    }
}
