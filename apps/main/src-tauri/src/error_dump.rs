//! Dev-only central error dump.
//!
//! Writes every error to `apps/main/error-dump.json` so developers can
//! inspect all failures in one place. No-ops in release builds.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;

static DUMP_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct ErrorEntry {
    pub timestamp: String,
    pub source: String,
    pub location: String,
    pub error: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stack: Option<String>,
}

/// Clear the dump file. Called on app startup so each launch starts fresh.
pub fn clear_on_launch() {
    if !cfg!(debug_assertions) {
        return;
    }
    let path = dump_file();
    let _ = fs::write(&path, "[]");
}

/// Resolve the dump file path once and cache it.
fn dump_file() -> PathBuf {
    let mut cached = DUMP_PATH.lock().unwrap();
    if let Some(ref p) = *cached {
        return p.clone();
    }
    // CARGO_MANIFEST_DIR = apps/main/src-tauri at compile time
    let manifest = env!("CARGO_MANIFEST_DIR");
    // Go up to apps/main/, the desktop app root
    let path = PathBuf::from(manifest)
        .parent()
        .unwrap()
        .join("error-dump.json");
    *cached = Some(path.clone());
    path
}

/// Append an error entry to the JSON dump file. No-op in release builds.
pub fn dump_error(source: &str, location: &str, error: &str, context: Option<serde_json::Value>) {
    if !cfg!(debug_assertions) {
        return;
    }
    let entry = ErrorEntry {
        timestamp: chrono::Utc::now().to_rfc3339(),
        source: source.to_string(),
        location: location.to_string(),
        error: error.to_string(),
        context,
        stack: None,
    };
    append_entry(entry);
}

fn append_entry(entry: ErrorEntry) {
    if !cfg!(debug_assertions) {
        return;
    }
    let path = dump_file();
    let mut entries: Vec<ErrorEntry> = if path.exists() {
        fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    entries.push(entry);
    if let Ok(json) = serde_json::to_string_pretty(&entries) {
        let _ = fs::write(&path, json);
    }
}

/// Tauri command: frontend can dump errors here too.
#[tauri::command]
pub fn dump_error_cmd(
    source: String,
    location: String,
    error: String,
    context: Option<String>,
    stack: Option<String>,
) -> Result<(), String> {
    if !cfg!(debug_assertions) {
        return Ok(());
    }
    let ctx: Option<serde_json::Value> = context.and_then(|c| serde_json::from_str(&c).ok());
    let entry = ErrorEntry {
        timestamp: chrono::Utc::now().to_rfc3339(),
        source,
        location,
        error,
        context: ctx,
        stack,
    };
    append_entry(entry);
    Ok(())
}

/// Tauri command: read the current dump file contents.
#[tauri::command]
pub fn read_error_dump() -> Result<String, String> {
    if !cfg!(debug_assertions) {
        return Ok("[]".to_string());
    }
    let path = dump_file();
    if !path.exists() {
        return Ok("[]".to_string());
    }
    fs::read_to_string(&path).map_err(|e| e.to_string())
}

/// Tauri command: clear the dump file.
#[tauri::command]
pub fn clear_error_dump() -> Result<(), String> {
    if !cfg!(debug_assertions) {
        return Ok(());
    }
    let path = dump_file();
    fs::write(&path, "[]").map_err(|e| e.to_string())
}

// ─── State dump ──────────────────────────────────────────────────────────────

static STATE_DUMP_PATH: Mutex<Option<PathBuf>> = Mutex::new(None);

fn state_dump_file() -> PathBuf {
    let mut cached = STATE_DUMP_PATH.lock().unwrap();
    if let Some(ref p) = *cached {
        return p.clone();
    }
    let manifest = env!("CARGO_MANIFEST_DIR");
    let path = PathBuf::from(manifest)
        .parent()
        .unwrap()
        .join("state-dump.json");
    *cached = Some(path.clone());
    path
}

/// Clear the state dump on launch.
pub fn clear_state_on_launch() {
    if !cfg!(debug_assertions) {
        return;
    }
    let path = state_dump_file();
    let _ = fs::write(&path, "{}");
}

/// Tauri command: write the state dump JSON (full overwrite, not append).
#[tauri::command]
pub fn dump_state_cmd(json: String) -> Result<(), String> {
    if !cfg!(debug_assertions) {
        return Ok(());
    }
    let path = state_dump_file();
    fs::write(&path, json).map_err(|e| e.to_string())
}
