use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredBook {
    pub filepath: String,
    pub filename: String,
    pub title: Option<String>,
    pub author: Option<String>,
    pub format: String,
    pub file_size: u64,
    pub folder: String,
    pub file_hash: String,
}

const SUPPORTED_EXTENSIONS: &[&str] = &["epub", "pdf", "mobi", "azw3", "djvu"];

const SKIP_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    "target",
    "__pycache__",
    ".Trash",
    ".cache",
    "Library/Caches",
    "AppData/Local/Temp",
    "AppData/Local/Microsoft",
    ".npm",
    ".cargo",
    ".rustup",
];

/// Returns platform-specific default book folders that exist on disk.
pub fn get_default_folders() -> Vec<String> {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return vec![],
    };

    let candidates: Vec<PathBuf> = if cfg!(target_os = "macos") {
        vec![
            home.join("Documents"),
            home.join("Downloads"),
            home.join("Library/Application Support/calibre"),
            home.join("Kindle"),
        ]
    } else if cfg!(target_os = "windows") {
        vec![
            home.join("Documents"),
            home.join("Downloads"),
            home.join("AppData/Roaming/calibre"),
            home.join("Kindle"),
        ]
    } else {
        // Linux
        vec![
            home.join("Documents"),
            home.join("Downloads"),
            home.join(".config/calibre"),
            home.join("Kindle"),
        ]
    };

    candidates
        .into_iter()
        .filter(|p| p.exists() && p.is_dir())
        .map(|p| p.to_string_lossy().to_string())
        .collect()
}

/// Returns the home directory path for full system scan.
pub fn get_home_dir() -> Option<String> {
    dirs::home_dir().map(|p| p.to_string_lossy().to_string())
}

/// Checks if a directory entry should be skipped.
fn should_skip(entry: &walkdir::DirEntry) -> bool {
    if !entry.file_type().is_dir() {
        return false;
    }
    let path_str = entry.path().to_string_lossy();
    SKIP_DIRS.iter().any(|skip| path_str.contains(skip))
}

/// Returns true if the file has a supported book extension.
fn is_book_file(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| SUPPORTED_EXTENSIONS.contains(&ext.to_lowercase().as_str()))
        .unwrap_or(false)
}

/// Walks a single folder and returns all book file paths found.
pub fn walk_folder(folder: &str) -> Vec<PathBuf> {
    WalkDir::new(folder)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| !should_skip(e))
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file() && is_book_file(e.path()))
        .map(|e| e.into_path())
        .collect()
}

/// Determines the book format from file extension.
pub fn format_from_path(path: &Path) -> String {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_lowercase())
        .unwrap_or_default()
}

/// Computes SHA-256 hash of a file.
pub fn hash_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    let bytes = std::fs::read(path).map_err(|e| format!("Failed to read file: {}", e))?;
    let hash = Sha256::digest(&bytes);
    Ok(format!("{:x}", hash))
}
