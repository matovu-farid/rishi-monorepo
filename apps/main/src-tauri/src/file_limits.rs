use serde::Serialize;
use std::path::Path;

const WARN_THRESHOLD: u64 = 200 * 1024 * 1024; // 200MB
const BLOCK_THRESHOLD_EPUB_PDF: u64 = 500 * 1024 * 1024; // 500MB
const BLOCK_THRESHOLD_MOBI_DJVU: u64 = 1024 * 1024 * 1024; // 1GB

#[derive(Debug, Serialize)]
#[serde(tag = "status")]
pub enum FileSizeCheck {
    #[serde(rename = "ok")]
    Ok,
    #[serde(rename = "warn")]
    Warn { size_bytes: u64 },
    #[serde(rename = "blocked")]
    Blocked { size_bytes: u64, limit_bytes: u64 },
}

pub fn check_file_size(path: &Path, format: &str) -> Result<FileSizeCheck, String> {
    let metadata = std::fs::metadata(path)
        .map_err(|e| format!("Cannot read file metadata: {}", e))?;
    let size = metadata.len();

    let block_threshold = match format {
        "epub" | "pdf" => BLOCK_THRESHOLD_EPUB_PDF,
        _ => BLOCK_THRESHOLD_MOBI_DJVU,
    };

    if size > block_threshold {
        Ok(FileSizeCheck::Blocked {
            size_bytes: size,
            limit_bytes: block_threshold,
        })
    } else if size > WARN_THRESHOLD {
        Ok(FileSizeCheck::Warn { size_bytes: size })
    } else {
        Ok(FileSizeCheck::Ok)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn create_file_of_size(size: usize) -> tempfile::NamedTempFile {
        let mut tmp = tempfile::NamedTempFile::new().unwrap();
        let buf = vec![0u8; size];
        tmp.write_all(&buf).unwrap();
        tmp.flush().unwrap();
        tmp
    }

    #[test]
    fn small_file_returns_ok() {
        let tmp = create_file_of_size(1024); // 1KB
        let result = check_file_size(tmp.path(), "epub").unwrap();
        assert!(matches!(result, FileSizeCheck::Ok));
    }

    #[test]
    fn file_above_warn_threshold_returns_warn() {
        // 201MB
        let size = 201 * 1024 * 1024;
        let tmp = create_file_of_size(size);
        let result = check_file_size(tmp.path(), "epub").unwrap();
        assert!(matches!(result, FileSizeCheck::Warn { .. }));
    }

    #[test]
    fn epub_above_500mb_returns_blocked() {
        // 501MB
        let size = 501 * 1024 * 1024;
        let tmp = create_file_of_size(size);
        let result = check_file_size(tmp.path(), "epub").unwrap();
        assert!(matches!(result, FileSizeCheck::Blocked { .. }));
    }

    #[test]
    fn pdf_above_500mb_returns_blocked() {
        let size = 501 * 1024 * 1024;
        let tmp = create_file_of_size(size);
        let result = check_file_size(tmp.path(), "pdf").unwrap();
        assert!(matches!(result, FileSizeCheck::Blocked { .. }));
    }

    #[test]
    fn mobi_at_600mb_returns_warn_not_blocked() {
        // 600MB — above warn but below 1GB mobi block
        let size = 600 * 1024 * 1024;
        let tmp = create_file_of_size(size);
        let result = check_file_size(tmp.path(), "mobi").unwrap();
        assert!(matches!(result, FileSizeCheck::Warn { .. }));
    }

    #[test]
    #[ignore = "requires >1GB of free disk/memory; run manually when disk space allows"]
    fn djvu_above_1gb_returns_blocked() {
        // 1GB + 1 byte
        let size = 1024 * 1024 * 1024 + 1;
        let tmp = create_file_of_size(size);
        let result = check_file_size(tmp.path(), "djvu").unwrap();
        assert!(matches!(result, FileSizeCheck::Blocked { .. }));
    }

    #[test]
    fn nonexistent_file_returns_error() {
        let result = check_file_size(Path::new("/nonexistent/file.epub"), "epub");
        assert!(result.is_err());
    }
}
