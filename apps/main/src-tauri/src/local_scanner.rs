use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::Emitter;
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
    pub file_hash: Option<String>,
}

const SUPPORTED_EXTENSIONS: &[&str] = &["epub", "pdf", "mobi", "azw3", "djvu"];

/// Directory names to skip during filesystem traversal.
const SKIP_DIR_NAMES: &[&str] = &[
    "node_modules",
    ".git",
    "target",
    "__pycache__",
    ".Trash",
    ".cache",
    ".npm",
    ".cargo",
    ".rustup",
];

/// Multi-component directory paths to skip (matched as path suffixes).
const SKIP_DIR_PATHS: &[&str] = &[
    "Library/Caches",
    "AppData/Local/Temp",
    "AppData/Local/Microsoft",
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
/// Matches single-component names exactly, and multi-component paths as suffixes.
fn should_skip(entry: &walkdir::DirEntry) -> bool {
    if !entry.file_type().is_dir() {
        return false;
    }
    let dir_name = entry.file_name().to_string_lossy();
    if SKIP_DIR_NAMES.iter().any(|skip| *skip == dir_name) {
        return true;
    }
    let path = entry.path();
    SKIP_DIR_PATHS.iter().any(|skip| path.ends_with(skip))
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

/// Computes a partial SHA-256 hash from the first 64KB of a file.
/// Fast and fixed-cost regardless of file size. Sufficient for dedup
/// since book file headers are effectively unique.
pub fn hash_file(path: &Path) -> Result<String, String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    const HASH_BYTES: usize = 65536; // 64KB

    let mut file =
        std::fs::File::open(path).map_err(|e| format!("Failed to open file: {}", e))?;
    let mut buf = vec![0u8; HASH_BYTES];
    let n = file
        .read(&mut buf)
        .map_err(|e| format!("Read error: {}", e))?;
    buf.truncate(n);

    let hash = Sha256::digest(&buf);
    Ok(format!("{:x}", hash))
}

static CANCEL_FLAG: AtomicBool = AtomicBool::new(false);
static SCAN_RUNNING: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanProgress {
    pub folder: String,
    pub scanned: u32,
    pub total: u32,
}

#[tauri::command]
pub fn get_default_book_folders() -> Vec<String> {
    get_default_folders()
}

#[tauri::command]
pub async fn scan_for_books(app: tauri::AppHandle, mode: String) -> Result<u32, String> {
    // Prevent concurrent scans
    if SCAN_RUNNING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        // A previous scan is still running — cancel it and wait briefly
        CANCEL_FLAG.store(true, Ordering::SeqCst);
        // Give the previous scan a moment to observe the flag
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        // Now take ownership
        SCAN_RUNNING.store(true, Ordering::SeqCst);
    }
    CANCEL_FLAG.store(false, Ordering::SeqCst);

    let result = tokio::task::spawn_blocking(move || {
        let folders: Vec<String> = if mode == "full" {
            match get_home_dir() {
                Some(home) => vec![home],
                None => return Err("Could not determine home directory".to_string()),
            }
        } else {
            get_default_folders()
        };

        let total_folders = folders.len() as u32;
        let mut total_found: u32 = 0;

        for (idx, folder) in folders.iter().enumerate() {
            if CANCEL_FLAG.load(Ordering::SeqCst) {
                break;
            }

            let _ = app.emit(
                "scan-progress",
                ScanProgress {
                    folder: folder.clone(),
                    scanned: idx as u32 + 1,
                    total: total_folders,
                },
            );

            let book_paths = walk_folder(folder);

            for path in book_paths {
                if CANCEL_FLAG.load(Ordering::SeqCst) {
                    break;
                }

                // Partial hash (first 64KB) — fast, fixed-cost regardless of file size
                let file_hash = match hash_file(&path) {
                    Ok(h) => h,
                    Err(_) => continue,
                };

                let file_size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);

                let filename = path
                    .file_name()
                    .map(|f| f.to_string_lossy().to_string())
                    .unwrap_or_default();

                let format = format_from_path(&path);

                // Use filename stem as display title (fast, no file parsing needed)
                let title = path
                    .file_stem()
                    .map(|s| s.to_string_lossy().to_string());

                let book = DiscoveredBook {
                    filepath: path.to_string_lossy().to_string(),
                    filename,
                    title,
                    author: None,
                    format,
                    file_size,
                    folder: folder.clone(),
                    file_hash: Some(file_hash),
                };

                let _ = app.emit("scan-result", book);
                total_found += 1;
            }
        }

        let _ = app.emit("scan-complete", total_found);
        Ok(total_found)
    })
    .await
    .map_err(|e| format!("Scan task panicked: {}", e))?;

    SCAN_RUNNING.store(false, Ordering::SeqCst);
    result
}

#[tauri::command]
pub fn cancel_scan() {
    CANCEL_FLAG.store(true, Ordering::SeqCst);
}


