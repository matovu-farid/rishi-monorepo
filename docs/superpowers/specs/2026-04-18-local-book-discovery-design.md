# Local Book Discovery — Design Spec

**Date:** 2026-04-18
**Platform:** Desktop (Tauri) only

## Overview

An "Import from Computer" button lets users scan their filesystem for book files and import them. The app scans platform-specific common book folders by default (fast), with an option to search the entire system (slower). No background indexing, no persistent index — every scan is fresh and on-demand.

## Goals

- Works out of the box — scans sensible default folders per OS with no config
- User-initiated only — never touches the filesystem until the user clicks the button
- Simple — no persistent index, no background tasks, no staleness tracking
- Full system search available — user can opt into a slower whole-system scan
- No App Store / notarization issues — scoped FS access with user-granted permissions

## Default Folder Detection

### Platform-specific defaults

| Platform | Default Locations |
|----------|-------------------|
| macOS | `~/Documents`, `~/Downloads`, `~/Library/Application Support/Calibre`, `~/Kindle` |
| Windows | `Documents`, `Downloads`, `%APPDATA%/Calibre`, `%USERPROFILE%/Kindle` |
| Linux | `~/Documents`, `~/Downloads`, `~/.config/calibre`, `~/Kindle` |

Only folders that actually exist on disk are scanned. Non-existent paths are silently skipped.

### Permission model

- Default folders: Tauri's `FsScope::allow_directory()` grants access when the user initiates a scan. On macOS, the OS may show a system-level permission dialog — this is expected behavior.
- Full system search: Uses the user's home directory as the root. The OS permission dialog covers this.
- No pre-emptive access — filesystem is only touched when the user clicks "Import from Computer".

## User Flow

### 1. Trigger

User clicks **"Import from Computer"** button in the library view (alongside existing import options like file picker and URL import).

### 2. Scan & Results View

A modal/panel opens showing:

```
┌──────────────────────────────────────────┐
│  IMPORT FROM COMPUTER                  ✕ │
│                                          │
│  🔍 Filter results...                   │
│                                          │
│  ○ Common folders (fast)                 │
│  ○ Search entire computer (slower)       │
│                                          │
│  Scanning... 3 of 4 folders              │
│  ████████████░░░░░░░░  60%               │
│                                          │
│  ── ~/Documents ──────────────────────── │
│  ┌──────────┐                            │
│  │ Atomic   │  Atomic Habits.epub        │
│  │ Habits   │  James Clear · 2.4 MB      │
│  │          │              [Import]      │
│  └──────────┘                            │
│  ┌──────────┐                            │
│  │ Deep     │  Deep Work.pdf             │
│  │ Work     │  Cal Newport · 5.1 MB      │
│  │          │              [Import]      │
│  └──────────┘                            │
│                                          │
│  ── ~/Downloads ──────────────────────── │
│  ┌──────────┐                            │
│  │ Dune     │  Dune.epub                 │
│  │          │  Frank Herbert · 1.8 MB    │
│  │          │              [Import]      │
│  └──────────┘                            │
│                                          │
│              [Import All]                │
└──────────────────────────────────────────┘
```

### 3. Key behaviors

- **Results stream in** as folders are scanned — no waiting for full completion
- **Filter field** filters the current results by title/author/filename (client-side, instant)
- **Grouped by folder** so the user knows where each book lives
- **Already-imported books are excluded** — compare `file_hash` against `books` table
- **Import button** per book — runs existing `addBook` pipeline (copy to app data dir, parse metadata, insert into DB, sync)
- **Import All** — bulk imports every discovered book

### 4. Search mode toggle

- **Common folders (default)** — Scans only the platform-specific default folders. Fast (seconds).
- **Search entire computer** — Recursively scans from the user's home directory, skipping system directories (e.g., `/System`, `/Library/System`, `node_modules`, `.git`, `AppData/Local/Temp`). Slower but thorough. Progress bar shows folder count.

## Scan Implementation

### Rust Tauri command: `scan_for_books`

```rust
#[derive(Serialize, Deserialize)]
pub struct DiscoveredBook {
    pub filepath: String,
    pub filename: String,
    pub title: Option<String>,
    pub author: Option<String>,
    pub format: String,       // epub, pdf, mobi, azw3, djvu
    pub file_size: u64,
    pub folder: String,       // parent folder display path
    pub file_hash: String,    // SHA-256 for dedup
}
```

**Input:** `mode: "default" | "full"` 
**Output:** Streams results via Tauri events, returns total count on completion.

**Events emitted:**
- `scan-progress` — `{ folder: String, scanned: u32, total: u32 }` 
- `scan-result` — `DiscoveredBook` (emitted per-book as found, so UI streams results in)
- `scan-complete` — `{ total: u32 }` 

### Pipeline

1. Determine folders to scan based on mode (`default` → platform defaults, `full` → home directory)
2. For each folder, walk recursively matching extensions: `.epub`, `.pdf`, `.mobi`, `.azw3`, `.djvu`
3. For each found file:
   - Compute `file_hash` (SHA-256)
   - Skip if hash matches an already-imported book in `books` table
   - Extract basic metadata (title, author) using existing `get_book_data` / `get_pdf_data` / etc.
   - If extraction fails, use filename as title
   - Emit `scan-result` event with the `DiscoveredBook`
4. Emit `scan-complete` when done

### Performance

- Runs on a Tokio background task, not the main thread
- Metadata extraction limited to title/author only (no full content parsing)
- Full system scan skips known non-book directories: `node_modules`, `.git`, `target`, `__pycache__`, `.Trash`, system directories
- SHA-256 computation is fast for typical book file sizes (1-50 MB)
- Scan is cancellable — user can close the modal to abort

### Tauri commands summary

| Command | Input | Output | Purpose |
|---------|-------|--------|---------|
| `get_default_book_folders` | none | `Vec<String>` | Returns platform-specific default folders that exist on disk |
| `scan_for_books` | `mode: String` | `u32` (total count) | Scans folders, emits `scan-result` events per book found, `scan-complete` when done |
| `cancel_scan` | none | none | Cancels an in-progress scan |

## Module Organization

- New file: `src-tauri/src/local_scanner.rs` — folder walking, metadata extraction, skip-list logic
- No new database tables — all results are ephemeral, held in frontend state during the modal
- No new Diesel migrations
- Commands registered in `main.rs` alongside existing ones

## UI Components

- **Import button** — Added to `FileComponent.tsx` alongside existing import options
- **Discovery modal** — New component showing scan results with filter, mode toggle, and import actions
- **Frontend state** — `useState` in the modal component. Results stored as `DiscoveredBook[]`, cleared when modal closes. No Zustand store needed since state is ephemeral.

## Import Behavior

- Clicking **Import** on a book calls the existing `addBook` pipeline from `books.ts`
- After successful import, the book is removed from the discovery results list (optimistic update)
- **Import All** iterates through all results sequentially, showing progress
- Import errors are shown inline per-book (e.g., "Failed to import — file may be corrupted")
