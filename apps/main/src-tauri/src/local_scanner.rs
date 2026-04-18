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

static CANCEL_FLAG: AtomicBool = AtomicBool::new(false);

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
pub async fn scan_for_books(
    app: tauri::AppHandle,
    mode: String,
) -> Result<u32, String> {
    CANCEL_FLAG.store(false, Ordering::SeqCst);

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

    let existing_hashes = get_existing_hashes()?;

    for (idx, folder) in folders.iter().enumerate() {
        if CANCEL_FLAG.load(Ordering::SeqCst) {
            break;
        }

        let _ = app.emit("scan-progress", ScanProgress {
            folder: folder.clone(),
            scanned: idx as u32 + 1,
            total: total_folders,
        });

        let book_paths = walk_folder(folder);

        for path in book_paths {
            if CANCEL_FLAG.load(Ordering::SeqCst) {
                break;
            }

            let file_hash = match hash_file(&path) {
                Ok(h) => h,
                Err(_) => continue,
            };

            if existing_hashes.contains(&file_hash) {
                continue;
            }

            let file_size = std::fs::metadata(&path)
                .map(|m| m.len())
                .unwrap_or(0);

            let filename = path
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_default();

            let format = format_from_path(&path);

            let (title, author) = extract_basic_metadata(&app, &path, &format);

            let book = DiscoveredBook {
                filepath: path.to_string_lossy().to_string(),
                filename,
                title,
                author,
                format,
                file_size,
                folder: folder.clone(),
                file_hash,
            };

            let _ = app.emit("scan-result", book);
            total_found += 1;
        }
    }

    let _ = app.emit("scan-complete", total_found);
    Ok(total_found)
}

#[tauri::command]
pub fn cancel_scan() {
    CANCEL_FLAG.store(true, Ordering::SeqCst);
}

fn extract_basic_metadata(
    app: &tauri::AppHandle,
    path: &Path,
    format: &str,
) -> (Option<String>, Option<String>) {
    use crate::commands;

    let result = match format {
        "epub" => commands::get_book_data(app.clone(), path),
        "pdf" => commands::get_pdf_data(app.clone(), path),
        "mobi" | "azw3" => commands::get_mobi_data(app.clone(), path),
        "djvu" => commands::get_djvu_data(app.clone(), path),
        _ => return (None, None),
    };

    match result {
        Ok(data) => (data.title, data.author),
        Err(_) => (None, None),
    }
}

fn get_existing_hashes() -> Result<std::collections::HashSet<String>, String> {
    use crate::db::DB_POOL;
    use crate::schema::books::dsl::*;
    use diesel::prelude::*;

    let pool = DB_POOL
        .get()
        .ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let hashes: Vec<Option<String>> = books
        .select(file_hash)
        .filter(is_deleted.eq(0))
        .load(&mut conn)
        .map_err(|e| format!("Failed to query hashes: {}", e))?;

    Ok(hashes.into_iter().flatten().collect())
}
