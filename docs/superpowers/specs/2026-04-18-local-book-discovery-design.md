# Local Book Discovery — Design Spec

**Date:** 2026-04-18
**Platform:** Desktop (Tauri) only

## Overview

Users can search for books already on their computer directly from the library search bar. The app indexes books in common filesystem locations, and search results show both imported library books and discoverable local files. Users can import any discovered book with one click.

## Goals

- Works out of the box with zero config — sensible default folders per OS
- User stays in control — can add/remove folders, re-scan on demand
- Never scans without consent — first-time prompt before any filesystem access
- No App Store / notarization issues — uses Tauri's scoped FS access with user-granted permissions
- Instant search — background indexing keeps results ready

## Default Folder Detection

### Platform-specific defaults

| Platform | Default Locations |
|----------|-------------------|
| macOS | `~/Documents`, `~/Downloads`, `~/Library/Application Support/Calibre`, `~/Kindle` |
| Windows | `Documents`, `Downloads`, `%APPDATA%/Calibre`, `%USERPROFILE%/Kindle` |
| Linux | `~/Documents`, `~/Downloads`, `~/.config/calibre`, `~/Kindle` |

### Permission flow

1. Detect OS via `tauri-plugin-os`
2. Resolve default folders for that platform
3. Check which folders actually exist on disk
4. Show a one-time setup prompt:
   > "Rishi can search these folders for books on your computer. You can add or remove folders anytime in Settings."
   
   Lists detected folders with toggles.
5. User confirms — app stores the approved folder list in `tauri-plugin-store`
6. For each approved folder, call `FsScope::allow_directory()` to register Tauri-level FS access

### Safety

- Only suggest folders, never scan without consent
- macOS sandboxed apps get a system-level permission dialog per folder — expected and trusted behavior
- Folders that don't exist are silently excluded
- User can add/remove folders anytime from Settings

## Background Indexing

### New SQLite table: `local_book_index`

| Column | Type | Purpose |
|--------|------|---------|
| `id` | INTEGER PK | Auto-increment |
| `filepath` | TEXT UNIQUE | Absolute path on disk |
| `filename` | TEXT | File name for search matching |
| `title` | TEXT (nullable) | Extracted from metadata if available |
| `author` | TEXT (nullable) | Extracted from metadata if available |
| `format` | TEXT | `epub`, `pdf`, `mobi`, `azw3`, `djvu` |
| `file_size` | INTEGER | Bytes |
| `folder` | TEXT | Which configured folder this came from |
| `file_hash` | TEXT (nullable) | SHA-256 for duplicate detection against imported books |
| `last_seen` | TIMESTAMP | Last time the file was confirmed on disk |
| `is_stale` | BOOLEAN | True if file was missing on last scan |

### Indexing pipeline (Rust background thread)

1. For each configured folder, walk recursively looking for files matching supported extensions (`.epub`, `.pdf`, `.mobi`, `.azw3`, `.djvu`)
2. For each found file:
   - Check if already in `local_book_index` by filepath
   - If new: extract basic metadata (title, author) using existing `get_book_data` commands, compute `file_hash`, insert row
   - If existing: update `last_seen`, un-mark `is_stale`
3. After scan completes, mark any rows for this folder where `last_seen` < scan start time as `is_stale`
4. Emit a Tauri event (`local-index-updated`) so the frontend knows to refresh results

### Performance

- Extract only title/author, not full content
- If extraction fails for a file, index it with `filename` as the display title
- Run on a Tokio background task, not the main thread
- For large folders, process in batches and emit progress events

### Duplicate detection

- Compare `file_hash` against the `books` table's `file_hash` column
- If a local file matches an already-imported book, don't show it in search results

### Re-index triggers

1. **On app launch** — Background scan runs automatically after startup (debounced, low priority)
2. **Manual refresh** — Refresh button in the UI for on-demand re-scan
3. **Folder config change** — When the user adds or removes a folder, re-index immediately
4. **File watcher (stretch goal)** — Optionally use `notify` Rust crate to watch folders for file changes and update the index incrementally. Avoids full re-scans but adds complexity — can be added later.

### Staleness handling

- During re-index, if a previously indexed file no longer exists on disk, mark it as `is_stale = true` (don't show in results)
- If a file reappears (e.g., external drive reconnected), un-mark it
- Full re-index replaces the entire index for a folder

## Search Integration

### Behavior

When the user types in the existing library search bar:

1. Frontend queries the `books` table (imported library results) as it does today
2. Simultaneously queries `local_book_index` where `is_stale = false` and `file_hash NOT IN (imported books' hashes)`, matching against `title`, `author`, and `filename`
3. Results displayed in two sections:

### Result layout

```
┌─────────────────────────────────────┐
│  YOUR LIBRARY                       │
│  ┌───────────┐                      │
│  │ Atomic... │  (already imported)  │
│  └───────────┘                      │
├─────────────────────────────────────┤
│  FOUND ON YOUR COMPUTER             │
│  ┌───────────┐                      │
│  │ Atomic... │  ~/Documents/Books   │
│  │           │  EPUB · 2.4 MB       │
│  │           │         [Import]     │
│  └───────────┘                      │
│  ┌───────────┐                      │
│  │ Atomic... │  ~/Downloads         │
│  │           │  PDF · 5.1 MB        │
│  │           │         [Import]     │
│  └───────────┘                      │
└─────────────────────────────────────┘
```

### Each local result shows

- Book title (or filename if metadata extraction failed)
- Author (if available)
- Folder location
- Format + file size
- **Import button** — runs the existing import flow (copy to app data dir, parse metadata, insert into `books` table, sync)

### Import behavior

- Reuse the existing `addBook` pipeline from `books.ts`
- After import, the book moves from "Found on your computer" to "Your library" section
- The `local_book_index` entry stays but is hidden (hash matches an imported book)

### Empty states

- No library matches + no local matches: "No books found"
- No local matches only: section doesn't appear
- Index still building: subtle "Scanning your folders..." indicator

## Settings: Book Folders

New section in the existing settings area:

```
┌─────────────────────────────────────┐
│  BOOK FOLDERS                       │
│                                     │
│  Rishi searches these folders for   │
│  books on your computer.            │
│                                     │
│  ✓ ~/Documents        [Remove]     │
│  ✓ ~/Downloads        [Remove]     │
│  ✓ ~/Calibre Library   [Remove]    │
│                                     │
│  [+ Add Folder]    [Re-scan Now]   │
│                                     │
│  Last scanned: 2 minutes ago        │
│  Found: 47 books                    │
└─────────────────────────────────────┘
```

### Behaviors

- **Add Folder** — Opens Tauri's folder picker dialog (`@tauri-apps/plugin-dialog`). Selected folder gets added to the stored list and triggers `FsScope::allow_directory()` + immediate index.
- **Remove** — Removes the folder from the list, deletes its entries from `local_book_index`, revokes scope access.
- **Re-scan Now** — Triggers a full re-index of all configured folders.
- **Folder list persistence** — Stored in `tauri-plugin-store`, survives app restarts.

### First-time experience

- On first use of the search feature (or first app launch after update), if no folders are configured, show the one-time setup prompt.
- After setup, the settings page is always available for adjustments.

## Rust Architecture

### New Tauri commands

| Command | Input | Output | Purpose |
|---------|-------|--------|---------|
| `get_default_book_folders` | none | `Vec<String>` | Returns platform-specific default folders that exist on disk |
| `scan_book_folders` | `folders: Vec<String>` | `u32` (count found) | Walks folders, indexes books, returns count. Emits `local-index-updated` on completion and `scan-progress` during scan |
| `search_local_books` | `query: String` | `Vec<LocalBook>` | Queries `local_book_index` using SQL `LIKE '%query%'` on title, author, and filename columns, excluding stale and already-imported entries. Case-insensitive. |
| `remove_folder_index` | `folder: String` | none | Deletes all index entries for a folder |

### New Rust struct

```rust
#[derive(Serialize, Deserialize)]
pub struct LocalBook {
    pub id: i32,
    pub filepath: String,
    pub filename: String,
    pub title: Option<String>,
    pub author: Option<String>,
    pub format: String,
    pub file_size: i64,
    pub folder: String,
}
```

### Module organization

- New file `src-tauri/src/local_scanner.rs` — folder walking, metadata extraction, index CRUD
- New Diesel migration for `local_book_index` table
- Commands registered in `main.rs` alongside existing ones

### Background scanning

- On app startup, spawn a `tokio::spawn` task that calls the scan logic
- Scan checks `FsScope` before accessing each folder — if scope was revoked or folder doesn't exist, skip it
- Metadata extraction reuses existing functions from `commands.rs` but catches errors gracefully (index with filename only if extraction fails)
