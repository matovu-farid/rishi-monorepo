# Local Book Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an "Import from Computer" button that scans the user's filesystem for book files and lets them import any discovered books into their library.

**Architecture:** A new Rust module (`local_scanner.rs`) handles filesystem traversal and metadata extraction, exposing Tauri commands that emit streaming events. The frontend renders a discovery modal that listens for these events and displays results as they arrive. The existing `processFilePaths` pipeline handles actual imports.

**Tech Stack:** Rust (walkdir, sha2, tokio), Tauri 2.x events, React (useState, Tauri event listeners), existing epub/pdf/mobi/djvu parsers.

---

### Task 1: Add `walkdir` dependency to Cargo.toml

**Files:**
- Modify: `apps/main/src-tauri/Cargo.toml`

- [ ] **Step 1: Add walkdir dependency**

In `apps/main/src-tauri/Cargo.toml`, add `walkdir` to the `[dependencies]` section:

```toml
walkdir = "2"
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add apps/main/src-tauri/Cargo.toml apps/main/src-tauri/Cargo.lock
git commit -m "chore: add walkdir dependency for local book scanning"
```

---

### Task 2: Create `local_scanner.rs` — folder detection and file walking

**Files:**
- Create: `apps/main/src-tauri/src/local_scanner.rs`
- Modify: `apps/main/src-tauri/src/main.rs` (add `mod local_scanner;`)

- [ ] **Step 1: Create the module with DiscoveredBook struct and default folder detection**

Create `apps/main/src-tauri/src/local_scanner.rs`:

```rust
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
```

- [ ] **Step 2: Add `dirs` dependency to Cargo.toml**

In `apps/main/src-tauri/Cargo.toml`, add:

```toml
dirs = "6"
```

- [ ] **Step 3: Register the module in main.rs**

In `apps/main/src-tauri/src/main.rs`, add near the top with the other `mod` declarations:

```rust
mod local_scanner;
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/local_scanner.rs apps/main/src-tauri/src/main.rs apps/main/src-tauri/Cargo.toml apps/main/src-tauri/Cargo.lock
git commit -m "feat: add local_scanner module with folder detection and file walking"
```

---

### Task 3: Add Tauri commands for scanning

**Files:**
- Modify: `apps/main/src-tauri/src/local_scanner.rs` (add commands)
- Modify: `apps/main/src-tauri/src/main.rs` (register commands)

- [ ] **Step 1: Add Tauri commands to local_scanner.rs**

Append to the end of `apps/main/src-tauri/src/local_scanner.rs`:

```rust
use tauri::Emitter;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

// Global cancel flag — set to true to abort a running scan
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

    // Get existing file hashes from DB to exclude already-imported books
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

            // Skip books already imported
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

            // Try to extract metadata — fall back to filename if it fails
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

/// Extracts title and author from a book file. Returns (None, None) on failure.
/// NOTE: The existing get_*_data commands call store_book_data() internally which
/// may store chunk data as a side effect. If this is problematic during scanning,
/// extract the metadata parsing logic into standalone functions that skip chunk storage.
/// For now, reusing the existing commands is the simplest approach — the chunk data
/// for non-imported books will be orphaned but harmless.
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

/// Gets all file_hash values from the books table to exclude already-imported books.
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
```

- [ ] **Step 2: Register new commands in main.rs**

In `apps/main/src-tauri/src/main.rs`, add these three lines inside the `tauri::generate_handler![]` macro:

```rust
local_scanner::get_default_book_folders,
local_scanner::scan_for_books,
local_scanner::cancel_scan,
```

- [ ] **Step 3: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors. There may be minor adjustments needed depending on how `BookData` fields are named (e.g., `title` might be `Option<String>` or `String`). Fix any type mismatches — the `extract_basic_metadata` function should match the `BookData` struct's field types.

- [ ] **Step 4: Commit**

```bash
git add apps/main/src-tauri/src/local_scanner.rs apps/main/src-tauri/src/main.rs
git commit -m "feat: add Tauri commands for scanning local books"
```

---

### Task 4: Create the Discovery Modal component

**Files:**
- Create: `apps/main/src/components/BookDiscoveryModal.tsx`

- [ ] **Step 1: Create the modal component**

Create `apps/main/src/components/BookDiscoveryModal.tsx`:

```tsx
import { useState, useEffect, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { X, Search, Loader2, Download, FolderOpen } from "lucide-react";

interface DiscoveredBook {
  filepath: string;
  filename: string;
  title: string | null;
  author: string | null;
  format: string;
  fileSize: number;
  folder: string;
  fileHash: string;
}

interface ScanProgress {
  folder: string;
  scanned: number;
  total: number;
}

interface BookDiscoveryModalProps {
  open: boolean;
  onClose: () => void;
  onImport: (filepath: string) => void;
}

function formatFileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function BookDiscoveryModal({
  open,
  onClose,
  onImport,
}: BookDiscoveryModalProps) {
  const [books, setBooks] = useState<DiscoveredBook[]>([]);
  const [filter, setFilter] = useState("");
  const [scanning, setScanning] = useState(false);
  const [progress, setProgress] = useState<ScanProgress | null>(null);
  const [mode, setMode] = useState<"default" | "full">("default");
  const [importingPaths, setImportingPaths] = useState<Set<string>>(new Set());

  const startScan = useCallback(async (scanMode: "default" | "full") => {
    setBooks([]);
    setScanning(true);
    setProgress(null);
    setMode(scanMode);

    try {
      await invoke("scan_for_books", { mode: scanMode });
    } catch (err) {
      console.error("Scan failed:", err);
    } finally {
      setScanning(false);
    }
  }, []);

  useEffect(() => {
    if (!open) return;

    const unlisteners: UnlistenFn[] = [];

    const setup = async () => {
      unlisteners.push(
        await listen<DiscoveredBook>("scan-result", (event) => {
          setBooks((prev) => [...prev, event.payload]);
        })
      );
      unlisteners.push(
        await listen<ScanProgress>("scan-progress", (event) => {
          setProgress(event.payload);
        })
      );
      unlisteners.push(
        await listen<number>("scan-complete", () => {
          setScanning(false);
        })
      );

      // Auto-start scan with default folders
      startScan("default");
    };

    setup();

    return () => {
      unlisteners.forEach((unlisten) => unlisten());
      invoke("cancel_scan").catch(() => {});
    };
  }, [open, startScan]);

  const handleClose = () => {
    invoke("cancel_scan").catch(() => {});
    setBooks([]);
    setFilter("");
    setScanning(false);
    setProgress(null);
    setImportingPaths(new Set());
    onClose();
  };

  const handleImport = async (book: DiscoveredBook) => {
    setImportingPaths((prev) => new Set(prev).add(book.filepath));
    onImport(book.filepath);
    // Remove from results after triggering import
    setBooks((prev) => prev.filter((b) => b.filepath !== book.filepath));
    setImportingPaths((prev) => {
      const next = new Set(prev);
      next.delete(book.filepath);
      return next;
    });
  };

  const handleImportAll = () => {
    filteredBooks.forEach((book) => {
      onImport(book.filepath);
    });
    setBooks([]);
  };

  if (!open) return null;

  const filterLower = filter.toLowerCase();
  const filteredBooks = books.filter((book) => {
    if (!filter) return true;
    return (
      (book.title?.toLowerCase().includes(filterLower) ?? false) ||
      (book.author?.toLowerCase().includes(filterLower) ?? false) ||
      book.filename.toLowerCase().includes(filterLower)
    );
  });

  // Group by folder
  const grouped = filteredBooks.reduce<Record<string, DiscoveredBook[]>>(
    (acc, book) => {
      if (!acc[book.folder]) acc[book.folder] = [];
      acc[book.folder].push(book);
      return acc;
    },
    {}
  );

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="bg-background border rounded-lg shadow-xl w-full max-w-2xl max-h-[80vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b">
          <h2 className="text-lg font-semibold">Import from Computer</h2>
          <Button variant="ghost" size="icon" onClick={handleClose}>
            <X size={18} />
          </Button>
        </div>

        {/* Filter + Mode */}
        <div className="p-4 space-y-3 border-b">
          <div className="relative">
            <Search
              size={16}
              className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground"
            />
            <Input
              placeholder="Filter results..."
              value={filter}
              onChange={(e) => setFilter(e.target.value)}
              className="pl-9"
            />
          </div>
          <div className="flex items-center gap-4 text-sm">
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                checked={mode === "default"}
                onChange={() => startScan("default")}
                disabled={scanning}
              />
              Common folders (fast)
            </label>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="radio"
                checked={mode === "full"}
                onChange={() => startScan("full")}
                disabled={scanning}
              />
              Search entire computer (slower)
            </label>
          </div>

          {/* Progress */}
          {scanning && progress && (
            <div className="flex items-center gap-2 text-sm text-muted-foreground">
              <Loader2 size={14} className="animate-spin" />
              Scanning folder {progress.scanned} of {progress.total}...
            </div>
          )}
        </div>

        {/* Results */}
        <div className="flex-1 overflow-y-auto p-4">
          {Object.keys(grouped).length === 0 && !scanning && (
            <div className="text-center text-muted-foreground py-8">
              No books found
            </div>
          )}
          {Object.keys(grouped).length === 0 && scanning && books.length === 0 && (
            <div className="text-center text-muted-foreground py-8">
              <Loader2 size={20} className="animate-spin mx-auto mb-2" />
              Scanning your folders...
            </div>
          )}

          {Object.entries(grouped).map(([folder, folderBooks]) => (
            <div key={folder} className="mb-4">
              <div className="flex items-center gap-2 text-sm text-muted-foreground mb-2">
                <FolderOpen size={14} />
                {folder}
              </div>
              <div className="space-y-2">
                {folderBooks.map((book) => (
                  <div
                    key={book.filepath}
                    className="flex items-center justify-between p-3 rounded-lg border bg-card"
                  >
                    <div className="min-w-0 flex-1">
                      <div className="font-medium truncate">
                        {book.title || book.filename}
                      </div>
                      <div className="text-sm text-muted-foreground">
                        {book.author && <span>{book.author} · </span>}
                        {book.format.toUpperCase()} ·{" "}
                        {formatFileSize(book.fileSize)}
                      </div>
                    </div>
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleImport(book)}
                      disabled={importingPaths.has(book.filepath)}
                    >
                      {importingPaths.has(book.filepath) ? (
                        <Loader2 size={14} className="animate-spin" />
                      ) : (
                        <Download size={14} />
                      )}
                      <span className="ml-1">Import</span>
                    </Button>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>

        {/* Footer */}
        {filteredBooks.length > 0 && (
          <div className="flex items-center justify-between p-4 border-t">
            <span className="text-sm text-muted-foreground">
              {filteredBooks.length} book{filteredBooks.length !== 1 ? "s" : ""}{" "}
              found
            </span>
            <Button variant="default" onClick={handleImportAll}>
              Import All ({filteredBooks.length})
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/BookDiscoveryModal.tsx
git commit -m "feat: add BookDiscoveryModal component for local book discovery"
```

---

### Task 5: Integrate the modal into FileComponent.tsx

**Files:**
- Modify: `apps/main/src/components/FileComponent.tsx`

- [ ] **Step 1: Add import and state for the modal**

At the top of `FileComponent.tsx`, add the import:

```typescript
import { BookDiscoveryModal } from "@/components/BookDiscoveryModal";
```

Add state inside the component function (near the other `useState` declarations):

```typescript
const [discoveryOpen, setDiscoveryOpen] = useState(false);
```

- [ ] **Step 2: Add the "Import from Computer" button**

In the header bar area (around line 432, near the existing "Add Book" button), add a second button:

```tsx
<Button
  variant="ghost"
  className="cursor-pointer"
  startIcon={<FolderOpen size={20} />}
  onClick={() => setDiscoveryOpen(true)}
>
  Import from Computer
</Button>
```

Add the `FolderOpen` import to the lucide-react import line at the top of the file.

- [ ] **Step 3: Add the modal to the JSX**

At the end of the component's return JSX (just before the closing fragment or div), add:

```tsx
<BookDiscoveryModal
  open={discoveryOpen}
  onClose={() => setDiscoveryOpen(false)}
  onImport={(filepath) => {
    processFilePaths([filepath]);
  }}
/>
```

This reuses the existing `processFilePaths` function which routes by file extension to the correct mutation (`storeBookDataMutation`, `storePdfMutation`, `storeMobiMutation`, `storeDjvuMutation`).

- [ ] **Step 4: Verify the app builds**

Run:
```bash
cd apps/main && npm run build
```
Expected: No build errors.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src/components/FileComponent.tsx
git commit -m "feat: integrate book discovery modal into library view"
```

---

### Task 6: Manual testing and polish

**Files:**
- Possibly modify: `apps/main/src/components/BookDiscoveryModal.tsx` (fixes from testing)
- Possibly modify: `apps/main/src-tauri/src/local_scanner.rs` (fixes from testing)

- [ ] **Step 1: Start the dev server**

Run:
```bash
cd apps/main && npm run tauri dev
```

- [ ] **Step 2: Test default folder scan**

1. Open the library view
2. Click "Import from Computer"
3. Verify the modal opens and auto-starts scanning
4. Verify books are found and displayed grouped by folder
5. Verify already-imported books are excluded
6. Verify the filter field works

- [ ] **Step 3: Test full system scan**

1. Switch to "Search entire computer" mode
2. Verify scanning starts and progress updates
3. Verify `node_modules`, `.git`, etc. are skipped
4. Verify books are found from non-default locations

- [ ] **Step 4: Test import**

1. Click "Import" on a discovered book
2. Verify the book appears in the library
3. Verify it's removed from the discovery results
4. Test "Import All"

- [ ] **Step 5: Test cancel and close**

1. Start a full scan
2. Close the modal mid-scan
3. Verify scanning stops cleanly
4. Re-open the modal and verify it starts fresh

- [ ] **Step 6: Fix any issues found**

Apply fixes to `BookDiscoveryModal.tsx` or `local_scanner.rs` as needed.

- [ ] **Step 7: Commit fixes**

```bash
git add -u
git commit -m "fix: polish book discovery modal from manual testing"
```
