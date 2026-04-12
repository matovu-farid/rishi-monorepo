# MOBI/AZW3 and DJVU Format Support

**Date**: 2026-04-12
**Status**: Approved

## Overview

Add dedicated viewers for MOBI/AZW3 and DJVU book formats to the Tauri desktop app. MOBI/AZW3 gets a reflowable HTML reader (like EPUB). DJVU gets a page-image viewer (like PDF). Both formats integrate with the existing TTS and AI chat premium features.

## Phased Delivery

1. **Phase 1 — Import pipeline**: Rust extractors for both formats (metadata, cover), file type detection, DB storage with new `kind` values
2. **Phase 2 — Dedicated viewers**: `MobiView` (reflowable) and `DjvuView` (page images) React components, route integration
3. **Phase 3 — TTS & AI chat**: Text extraction for both formats feeding into existing TTS queue and chat/embedding pipeline

## Architecture

### Approach: Full Rust Backend

All parsing, rendering, and text extraction happens in Rust via Tauri commands. The frontend receives processed data (HTML strings, PNG bytes, plain text) and renders it.

### New Rust Modules

- `src-tauri/src/mobi.rs` — MOBI/AZW3 parser implementing `Extractable`, plus chapter HTML extraction commands
- `src-tauri/src/djvu.rs` — DJVU page renderer implementing `Extractable`, plus page image and text extraction commands

### New Frontend Components

- `src/components/mobi/MobiView.tsx` — Reflowable HTML reader (themes, font sizing, chapter nav)
- `src/components/djvu/DjvuView.tsx` — Page-image viewer (page nav, zoom, thumbnails)

### Existing Code Touchpoints

- `BookKind` enum (`shared/types.rs`): add `Mobi = 2` and `Djvu = 3` variants
- `chooseFiles.ts`: add `.mobi`, `.azw3`, `.djvu` to file picker filters
- `FileComponent.tsx`: add format detection, new import mutations, new allowed extensions
- `books.$id.lazy.tsx`: route to new viewers based on `kind`
- `commands.rs`: register new Tauri commands
- `lib.rs`: register commands with Tauri invoke handler
- No DB schema changes needed — `kind` is already a free-form `TEXT` column

---

## MOBI/AZW3 — Rust Backend

### Crate

`mobi` — pure Rust, supports MOBI and KF8/AZW3 formats.

### Metadata Extraction (`mobi.rs` implementing `Extractable`)

- Parse MOBI header for title, author, publisher
- Extract cover image from EXTH records (cover offset -> image record)
- Return `BookData` with `kind: "mobi"`
- AZW3 files get the same `kind` — same format family

### Chapter Extraction (Tauri commands)

**`get_mobi_chapter(path, chapter_index) -> String`**:
- Parse the MOBI file, extract raw HTML content
- Split by chapter markers (`<mbp:pagebreak>` for MOBI, filepos markers for KF8)
- Return chapter HTML for the given index

**`get_mobi_chapter_count(path) -> u32`**:
- Return total number of chapters

### Text Extraction (Tauri command)

**`get_mobi_text(path, chapter_index) -> Vec<String>`**:
- Strip HTML tags from chapter content
- Return plain text split into paragraphs
- Feeds into existing `process_job` / `embed_text` pipeline for TTS and embeddings

---

## DJVU — Rust Backend

### Library

`djvulibre-sys` — FFI bindings to the `djvulibre` C library, statically linked.

### Metadata Extraction (`djvu.rs` implementing `Extractable`)

- Open DJVU document via `ddjvu_document_create`
- Extract page count, title from document annotations (DJVU metadata is sparse — title/author may not exist)
- Render first page as a thumbnail for the cover image
- Return `BookData` with `kind: "djvu"`, fallback cover if metadata missing

### Page Rendering (Tauri command)

**`get_djvu_page(path, page_number, dpi) -> Vec<u8>`**:
- Default DPI of 300 for crisp rendering
- Decode page via `ddjvu_page_create_by_pageno`
- Render to RGB buffer, encode as PNG bytes
- Return PNG image data to frontend

**`get_djvu_page_count(path) -> u32`**:
- Return total number of pages

### Text Extraction (Tauri command)

**`get_djvu_page_text(path, page_number) -> Vec<String>`**:
- Use `ddjvu_document_get_pagetext` to pull OCR text layer
- Parse the S-expression text format (djvulibre nests words/lines/paragraphs)
- Return plain text per page, split into paragraphs
- If no text layer exists, return empty — TTS and chat gracefully degrade

### Build Considerations

- `djvulibre-sys` needs `cmake` at build time for the C library
- Static linking avoids runtime dependency on user's machine
- macOS/Linux straightforward; Windows needs bundled C source compiled via `cc` crate

---

## Frontend — MobiView

**File**: `src/components/mobi/MobiView.tsx`

### Architecture

Reflowable HTML rendered in a sandboxed iframe with theme injection. Similar UX to `EpubView`.

### Rendering

- On mount, call `get_mobi_chapter_count(path)` to get total chapters
- Load current chapter HTML via `get_mobi_chapter(path, chapterIndex)`
- Render HTML inside an iframe using `srcdoc`
- Inject active theme CSS (color, background, font-size from `themes.ts`) into the HTML before setting `srcdoc`

### Navigation

- Prev/next chapter buttons update `chapterIndex`, load new HTML
- Reading position tracked as `chapterIndex` in the book's `location` field

### Theme Support

Wrap chapter HTML with a `<style>` block applying the active theme's colors and font size — same values the EPUB reader uses.

### Text Selection

Listen for `message` events from the iframe for selection (for future highlighting support).

### TTS Integration (Phase 3)

- Call `get_mobi_text(path, chapterIndex)` to get paragraphs
- Feed into existing `Player` / `ttsQueue` — same flow as EPUB
- Highlight current paragraph by injecting a CSS class into the iframe

### Controls

`<TTSControls>` at the bottom, chat button gated by `useRequireAuth` — same as EPUB.

---

## Frontend — DjvuView

**File**: `src/components/djvu/DjvuView.tsx`

### Architecture

Page-image viewer mirroring `PdfView`. Each page rendered as a PNG image.

### Rendering

- On mount, call `get_djvu_page_count(path)` to get total pages
- Render current page via `get_djvu_page(path, pageNumber, dpi)` — returns PNG bytes
- Convert bytes to blob URL, display as `<img>` element

### Navigation

- Prev/next buttons, page number input, keyboard arrows
- Reading position tracked as `pageNumber` in the book's `location` field (same as PDF)

### Prefetching

- Preload next and previous pages in background
- Cache last ~5 rendered pages in memory to avoid re-requesting from Rust

### Zoom

- CSS `transform: scale()` on the image container
- Default to fit-width
- Optional: re-request at higher DPI for sharper zoom instead of CSS scaling

### Thumbnail Sidebar

Render small page versions (low DPI ~72) in a sidebar panel, same pattern as PDF's `ThumbnailSidebar`.

### TTS Integration (Phase 3)

- Call `get_djvu_page_text(path, pageNumber)` to get paragraphs
- If text layer exists, feed into `Player` / `ttsQueue`
- If no text layer, show toast: "No text available for this page"
- No paragraph highlighting (it's an image) — just play audio sequentially

### Controls

`<TTSControls>` overlay, voice chat via mic button, gated by `useRequireAuth` — same as PDF.

---

## Import Pipeline Changes

### `chooseFiles.ts`

Add filter entries:
- `{ name: "MOBI Books", extensions: ["mobi", "azw3"] }`
- `{ name: "DJVU Documents", extensions: ["djvu"] }`

### `FileComponent.tsx`

- `allowedExtensions`: add `".mobi"`, `".azw3"`, `".djvu"`
- `processFilePaths`: `.mobi`/`.azw3` call `storeMobiMutation`, `.djvu` calls `storeDjvuMutation`
- Both mutations follow existing pattern: copy to app data -> extract metadata via Rust -> `saveBook()` -> hash + R2 upload

### `BookKind` enum (`shared/types.rs`)

Add `Mobi = 2` and `Djvu = 3` variants. `.to_string()` returns `"mobi"` and `"djvu"`.

### `commands.rs`

Register new commands:
- `get_mobi_data(path)` — metadata extraction
- `get_djvu_data(path)` — metadata extraction
- `get_mobi_chapter`, `get_mobi_chapter_count`, `get_mobi_text`
- `get_djvu_page`, `get_djvu_page_count`, `get_djvu_page_text`

### `books.$id.lazy.tsx`

Add two new render branches:
- `book.kind === "mobi"` -> `<MobiView />`
- `book.kind === "djvu"` -> `<DjvuView />`

---

## Error Handling

- **Corrupt/DRM files**: MOBI parser returns error on DRM-protected files (Kindle DRM). Show user-facing error: "This book has DRM protection and cannot be opened."
- **Missing DJVU text layer**: TTS and chat degrade gracefully — no crash, just an informational message.
- **Large DJVU files**: Page rendering is on-demand, so memory stays bounded regardless of file size.
- **Missing metadata**: All metadata fields (title, author, publisher) fall back to filename / "Unknown" / empty, same as existing EPUB/PDF handling.
