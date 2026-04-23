use memmap2::Mmap;
use std::path::Path;

/// Memory-map an entire file read-only.
/// The OS pages in content on demand — only accessed regions occupy physical RAM.
pub fn mmap_file(path: &Path) -> Result<Mmap, Box<dyn std::error::Error>> {
    let file = std::fs::File::open(path)?;
    // SAFETY: File is opened read-only and we hold the handle for the
    // lifetime of the Mmap. Caller must not truncate the file while mapped.
    let mmap = unsafe { Mmap::map(&file)? };
    Ok(mmap)
}

/// Read the first `n` bytes of a file via mmap.
/// Only the first OS page (~4KB) is paged into physical RAM.
pub fn read_magic(path: &Path, n: usize) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mmap = mmap_file(path)?;
    if mmap.len() < n {
        return Err(format!(
            "File too small: expected at least {} bytes, got {}",
            n,
            mmap.len()
        )
        .into());
    }
    Ok(mmap[..n].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn mmap_file_returns_correct_contents() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"hello world").unwrap();
        tmp.flush().unwrap();

        let mmap = mmap_file(tmp.path()).unwrap();
        assert_eq!(&mmap[..], b"hello world");
    }

    #[test]
    fn mmap_file_nonexistent_returns_error() {
        let result = mmap_file(Path::new("/nonexistent/path.bin"));
        assert!(result.is_err());
    }

    #[test]
    fn read_magic_returns_first_n_bytes() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"AT&TFORM").unwrap();
        tmp.flush().unwrap();

        let magic = read_magic(tmp.path(), 4).unwrap();
        assert_eq!(&magic, b"AT&T");
    }

    #[test]
    fn read_magic_file_too_small_returns_error() {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        tmp.write_all(b"AB").unwrap();
        tmp.flush().unwrap();

        let result = read_magic(tmp.path(), 4);
        assert!(result.is_err());
        assert!(
            result.unwrap_err().to_string().contains("File too small"),
        );
    }
}
