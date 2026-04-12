# MOBI/DJVU Phase 2: Dedicated Viewers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users can read MOBI/AZW3 books in a reflowable themed reader and DJVU documents in a page-image viewer, replacing the Phase 1 placeholder screens.

**Architecture:** MOBI: Rust extracts HTML per chapter, frontend renders in a themed iframe with chapter navigation. DJVU: Rust renders pages to PNG via djvulibre FFI, frontend displays images with page navigation, zoom, and thumbnails.

**Tech Stack:** Rust `mobi` crate, Rust `djvulibre` C FFI, React, Jotai atoms, iframe srcdoc rendering, blob URLs

**Prerequisite:** Phase 1 (import pipeline) must be complete.

---

### Task 1: Add MOBI chapter extraction Tauri commands

**Files:**
- Modify: `apps/main/src-tauri/src/mobi.rs`
- Modify: `apps/main/src-tauri/src/commands.rs`
- Modify: `apps/main/src-tauri/src/lib.rs`

- [ ] **Step 1: Add chapter extraction functions to mobi.rs**

Add the following functions at the end of `apps/main/src-tauri/src/mobi.rs`:

```rust
/// Split MOBI HTML content into chapters by page break markers.
pub fn get_chapters(path: &Path) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let doc = MobiDoc::from_path(path)?;
    let content = doc.content_as_string()?;

    // KF8/AZW3 and MOBI use <mbp:pagebreak/> as chapter separators
    let chapters: Vec<String> = content
        .split("<mbp:pagebreak/>")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    // If no page breaks found, treat entire content as one chapter
    if chapters.is_empty() {
        Ok(vec![content])
    } else {
        Ok(chapters)
    }
}

/// Get the HTML content for a specific chapter.
pub fn get_chapter(path: &Path, chapter_index: u32) -> Result<String, Box<dyn std::error::Error>> {
    let chapters = get_chapters(path)?;
    let idx = chapter_index as usize;
    if idx >= chapters.len() {
        return Err(format!(
            "Chapter index {} out of range (total: {})",
            idx,
            chapters.len()
        )
        .into());
    }
    Ok(chapters[idx].clone())
}

/// Get the number of chapters in a MOBI file.
pub fn get_chapter_count(path: &Path) -> Result<u32, Box<dyn std::error::Error>> {
    let chapters = get_chapters(path)?;
    Ok(chapters.len() as u32)
}

/// Extract plain text paragraphs from a specific chapter (for TTS/embeddings).
pub fn get_chapter_text(path: &Path, chapter_index: u32) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let html = get_chapter(path, chapter_index)?;
    // Strip HTML tags to get plain text
    let text = strip_html_tags(&html);
    // Split into paragraphs by double newlines or <p> boundaries
    let paragraphs: Vec<String> = text
        .split('\n')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();
    Ok(paragraphs)
}

/// Simple HTML tag stripper.
fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut in_tag = false;
    let mut last_was_block = false;

    for ch in html.chars() {
        match ch {
            '<' => {
                in_tag = true;
                // Check for block-level tags to insert newlines
                let remaining = &html[html.len().saturating_sub(result.len())..];
                if remaining.starts_with("<p") || remaining.starts_with("<div") || remaining.starts_with("<br") {
                    if !last_was_block {
                        result.push('\n');
                        last_was_block = true;
                    }
                }
            }
            '>' => {
                in_tag = false;
            }
            _ if !in_tag => {
                result.push(ch);
                last_was_block = false;
            }
            _ => {}
        }
    }
    result
}
```

- [ ] **Step 2: Add Tauri commands in commands.rs**

Add after the `get_mobi_data` command in `commands.rs`:

```rust
#[tauri::command]
pub fn get_mobi_chapter(path: &Path, chapter_index: u32) -> Result<String, String> {
    crate::mobi::get_chapter(path, chapter_index).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_mobi_chapter_count(path: &Path) -> Result<u32, String> {
    crate::mobi::get_chapter_count(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_mobi_text(path: &Path, chapter_index: u32) -> Result<Vec<String>, String> {
    crate::mobi::get_chapter_text(path, chapter_index).map_err(|e| e.to_string())
}
```

- [ ] **Step 3: Register commands in lib.rs**

Add to the `invoke_handler` list in `lib.rs`:

```rust
commands::get_mobi_chapter,
commands::get_mobi_chapter_count,
commands::get_mobi_text,
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles. If the `mobi` crate API differs (e.g. `content_as_string` doesn't exist), check `cargo doc --open -p mobi` and adjust.

- [ ] **Step 5: Commit**

```bash
git add apps/main/src-tauri/src/mobi.rs apps/main/src-tauri/src/commands.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add MOBI chapter extraction Tauri commands"
```

---

### Task 2: Add MOBI TypeScript bindings

**Files:**
- Modify: `apps/main/src/generated/types.ts`
- Modify: `apps/main/src/generated/commands.ts`

- [ ] **Step 1: Add param types to types.ts**

Add to `apps/main/src/generated/types.ts`:

```typescript
export interface GetMobiChapterParams {
  path: Path;
  chapterIndex: number;
  [key: string]: unknown;
}

export interface GetMobiChapterCountParams {
  path: Path;
  [key: string]: unknown;
}

export interface GetMobiTextParams {
  path: Path;
  chapterIndex: number;
  [key: string]: unknown;
}
```

- [ ] **Step 2: Add command functions to commands.ts**

Add to `apps/main/src/generated/commands.ts`:

```typescript
export async function getMobiChapter(params: types.GetMobiChapterParams): Promise<string> {
  return invoke('get_mobi_chapter', params);
}

export async function getMobiChapterCount(params: types.GetMobiChapterCountParams): Promise<number> {
  return invoke('get_mobi_chapter_count', params);
}

export async function getMobiText(params: types.GetMobiTextParams): Promise<string[]> {
  return invoke('get_mobi_text', params);
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/generated/types.ts apps/main/src/generated/commands.ts
git commit -m "feat: add MOBI chapter TypeScript bindings"
```

---

### Task 3: Create MobiView component

**Files:**
- Create: `apps/main/src/components/mobi/MobiView.tsx`

- [ ] **Step 1: Create MobiView component**

Create `apps/main/src/components/mobi/MobiView.tsx`:

```tsx
import React, { useCallback, useEffect, useRef, useState } from "react";
import { useAtom } from "jotai";
import { ChevronLeft, ChevronRight, Palette } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import { Menu } from "@components/ui/Menu";
import { Radio, RadioGroup } from "@components/ui/Radio";
import { ThemeType } from "@/themes/common";
import { themes } from "@/themes/themes";
import { themeAtom } from "@/stores/epub_atoms";
import { getMobiChapter, getMobiChapterCount, updateBookLocation } from "@/generated";
import type { Book } from "@/generated";
import { BackButton } from "@components/BackButton";
import TTSControls from "@components/TTSControls";

export function MobiView({ book }: { book: Book }) {
  const [theme, setTheme] = useAtom(themeAtom);
  const [menuOpen, setMenuOpen] = useState(false);
  const [chapterIndex, setChapterIndex] = useState(
    parseInt(book.location, 10) || 0
  );
  const [chapterCount, setChapterCount] = useState(0);
  const [chapterHtml, setChapterHtml] = useState<string>("");
  const [isLoading, setIsLoading] = useState(true);
  const iframeRef = useRef<HTMLIFrameElement>(null);

  // Load chapter count on mount
  useEffect(() => {
    getMobiChapterCount({ path: book.filepath }).then((count) => {
      setChapterCount(count);
    });
  }, [book.filepath]);

  // Load chapter HTML when chapter index changes
  useEffect(() => {
    if (chapterCount === 0) return;
    setIsLoading(true);
    getMobiChapter({ path: book.filepath, chapterIndex }).then((html) => {
      setChapterHtml(html);
      setIsLoading(false);
    });
    // Persist reading position
    void updateBookLocation({ bookId: book.id, newLocation: String(chapterIndex) });
  }, [chapterIndex, chapterCount, book.filepath, book.id]);

  const handlePrevChapter = useCallback(() => {
    setChapterIndex((prev) => Math.max(0, prev - 1));
  }, []);

  const handleNextChapter = useCallback(() => {
    setChapterIndex((prev) => Math.min(chapterCount - 1, prev + 1));
  }, [chapterCount]);

  // Keyboard navigation
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft") handlePrevChapter();
      if (e.key === "ArrowRight") handleNextChapter();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [handlePrevChapter, handleNextChapter]);

  const handleThemeChange = (newTheme: ThemeType) => {
    setTheme(newTheme);
    setMenuOpen(false);
  };

  // Build themed HTML for iframe srcdoc
  const themedHtml = `
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8" />
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          background: ${themes[theme].background};
          color: ${themes[theme].color};
          font-family: Georgia, 'Times New Roman', serif;
          font-size: 1.2em;
          line-height: 1.8;
          padding: 2rem 3rem;
          max-width: 800px;
          margin: 0 auto;
        }
        p { margin-bottom: 1em; }
        h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 0.5em; }
        img { max-width: 100%; height: auto; }
        a { color: inherit; }
      </style>
    </head>
    <body>${chapterHtml}</body>
    </html>
  `;

  function getTextColor() {
    switch (theme) {
      case ThemeType.White:
        return "text-black hover:bg-black/10 hover:text-black";
      case ThemeType.Dark:
        return "text-white hover:bg-white/10 hover:text-white";
      default:
        return "text-black hover:bg-black/10 hover:text-black";
    }
  }

  return (
    <div className="relative" style={{ background: themes[theme].background }}>
      {/* Top bar */}
      <div className="absolute right-2 top-2 z-10 flex items-center gap-2">
        <BackButton />

        <Menu
          trigger={
            <IconButton className="hover:bg-transparent border-none">
              <Palette size={20} className={getTextColor()} />
            </IconButton>
          }
          open={menuOpen}
          onOpen={() => setMenuOpen(true)}
          onClose={() => setMenuOpen(false)}
          anchorOrigin={{ vertical: "bottom", horizontal: "right" }}
          theme={themes[theme]}
        >
          <div className="p-3">
            <RadioGroup
              value={theme}
              onChange={(value) => handleThemeChange(value as ThemeType)}
              name="theme-selector"
              theme={themes[theme]}
            >
              {(Object.keys(themes) as Array<keyof typeof themes>).map(
                (themeKey) => (
                  <Radio
                    key={themeKey}
                    value={themeKey}
                    label={themeKey}
                    theme={themes[theme]}
                  />
                )
              )}
            </RadioGroup>
          </div>
        </Menu>
      </div>

      {/* Chapter navigation bar */}
      <div className="absolute bottom-20 left-1/2 -translate-x-1/2 z-10 flex items-center gap-3 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg">
        <IconButton
          onClick={handlePrevChapter}
          disabled={chapterIndex <= 0}
          className="text-white hover:bg-white/10 disabled:text-white/30"
        >
          <ChevronLeft size={20} />
        </IconButton>
        <span className="text-white text-sm min-w-[80px] text-center">
          {chapterIndex + 1} / {chapterCount}
        </span>
        <IconButton
          onClick={handleNextChapter}
          disabled={chapterIndex >= chapterCount - 1}
          className="text-white hover:bg-white/10 disabled:text-white/30"
        >
          <ChevronRight size={20} />
        </IconButton>
      </div>

      {/* Content iframe */}
      <div style={{ height: "100vh", position: "relative" }}>
        {isLoading ? (
          <div className="w-full h-full flex items-center justify-center">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-400" />
          </div>
        ) : (
          <iframe
            ref={iframeRef}
            srcDoc={themedHtml}
            title={book.title}
            className="w-full h-full border-none"
            sandbox="allow-same-origin"
          />
        )}
      </div>

      {/* TTS Controls */}
      <TTSControls bookId={book.id.toString()} />
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/mobi/MobiView.tsx
git commit -m "feat: add MobiView reflowable reader component"
```

---

### Task 4: Add djvulibre-sys dependency and DJVU page rendering

**Files:**
- Modify: `apps/main/src-tauri/Cargo.toml`
- Modify: `apps/main/src-tauri/src/djvu.rs`
- Modify: `apps/main/src-tauri/src/commands.rs`
- Modify: `apps/main/src-tauri/src/lib.rs`

Note: If `djvulibre-sys` is not available on crates.io or is difficult to build, use the alternative approach described at the end of this task: shell out to `ddjvu` CLI instead of FFI. Check `cargo search djvulibre` first.

- [ ] **Step 1: Add djvulibre dependency**

If a `djvulibre-sys` or `djvulibre` crate exists on crates.io, add it:

```toml
djvulibre = "0.x"  # Use whatever version is available
```

**Alternative if no crate exists:** Use the `std::process::Command` approach to shell out to `ddjvu` and `djvutxt` CLI tools. In that case, add no new Cargo dependency — skip to Step 2 alternative.

- [ ] **Step 2: Add page rendering and text extraction to djvu.rs**

Replace the contents of `apps/main/src-tauri/src/djvu.rs` with the CLI-based approach (most portable):

```rust
use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

pub struct Djvu {
    pub path: PathBuf,
}

impl Djvu {
    pub fn new(path: &Path) -> Self {
        Djvu {
            path: path.to_path_buf(),
        }
    }
}

impl Extractable for Djvu {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let djvu_path = &self.path;

        if !djvu_path.exists() {
            return Err(format!("File not found: {}", djvu_path.display()).into());
        }

        // Validate DJVU magic bytes: "AT&TFORM"
        let header = fs::read(djvu_path)?;
        if header.len() < 8 || &header[0..4] != b"AT&T" {
            return Err("Not a valid DJVU file".into());
        }

        // Derive title from filename
        let title = djvu_path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string());

        // Try to render first page as cover, fall back to placeholder
        let cover = render_page_to_png(djvu_path, 1, 72)
            .unwrap_or_else(|_| create_djvu_placeholder_cover());
        let cover_kind = if render_page_to_png(djvu_path, 1, 72).is_ok() {
            None
        } else {
            Some("fallback".to_string())
        };

        let digest = md5::compute(djvu_path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = djvu_path.to_string_lossy().to_string();
        let kind = BookKind::Djvu.to_string();
        let current_location = "1".to_string();

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            None,
            None,
            file_path,
            current_location,
            cover_kind,
        ))
    }
}

/// Render a DJVU page to PNG bytes using ddjvu CLI tool.
pub fn render_page_to_png(path: &Path, page: u32, dpi: u32) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let tmp_path = std::env::temp_dir().join(format!("rishi_djvu_page_{}_{}.ppm", page, dpi));

    let output = Command::new("ddjvu")
        .args([
            "-format=ppm",
            &format!("-page={}", page),
            &format!("-size={}x{}", dpi * 8, dpi * 11), // ~letter size at given DPI
            &path.to_string_lossy(),
            &tmp_path.to_string_lossy(),
        ])
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("ddjvu failed: {}", stderr).into());
    }

    // Read PPM and convert to PNG
    let ppm_data = fs::read(&tmp_path)?;
    let _ = fs::remove_file(&tmp_path); // cleanup

    let img = image::load_from_memory_with_format(&ppm_data, image::ImageFormat::Pnm)?;
    let mut png_buf = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut png_buf);
    img.write_to(&mut cursor, image::ImageFormat::Png)?;

    Ok(png_buf)
}

/// Get the page count of a DJVU file using djvused CLI.
pub fn get_page_count(path: &Path) -> Result<u32, Box<dyn std::error::Error>> {
    let output = Command::new("djvused")
        .args([&path.to_string_lossy().to_string(), "-e", "n"])
        .output()?;

    if !output.status.success() {
        return Err("djvused failed to get page count".into());
    }

    let count_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let count: u32 = count_str.parse()?;
    Ok(count)
}

/// Extract text from a specific DJVU page using djvutxt CLI.
pub fn get_page_text(path: &Path, page: u32) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let output = Command::new("djvutxt")
        .args([
            &format!("--page={}", page),
            &path.to_string_lossy(),
        ])
        .output()?;

    if !output.status.success() {
        // No text layer is common for scanned docs — return empty
        return Ok(vec![]);
    }

    let text = String::from_utf8_lossy(&output.stdout).to_string();
    let paragraphs: Vec<String> = text
        .split('\n')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    Ok(paragraphs)
}

/// Generate a placeholder cover for DJVU files.
fn create_djvu_placeholder_cover() -> Vec<u8> {
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    let width = 400u32;
    let height = 600u32;
    let mut img = RgbaImage::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let gradient_y = (y as f32 / height as f32).min(1.0);
        let noise = ((x + y) % 7) as u8 * 3;
        let edge_darken = if x < 20 || x > width - 20 || y < 20 || y > height - 20 {
            20
        } else {
            0
        };
        *pixel = Rgba([
            (50 + (gradient_y * 25.0) as u8 + noise).saturating_sub(edge_darken),
            (55 + (gradient_y * 30.0) as u8 + noise).saturating_sub(edge_darken),
            (70 + (gradient_y * 35.0) as u8 + noise).saturating_sub(edge_darken),
            255,
        ]);
    }

    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .unwrap_or_default();
    buffer
}
```

- [ ] **Step 3: Add DJVU Tauri commands to commands.rs**

Add after the `get_djvu_data` command in `commands.rs`:

```rust
#[tauri::command]
pub fn get_djvu_page(path: &Path, page_number: u32, dpi: u32) -> Result<Vec<u8>, String> {
    crate::djvu::render_page_to_png(path, page_number, dpi).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_page_count(path: &Path) -> Result<u32, String> {
    crate::djvu::get_page_count(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_page_text(path: &Path, page_number: u32) -> Result<Vec<String>, String> {
    crate::djvu::get_page_text(path, page_number).map_err(|e| e.to_string())
}
```

- [ ] **Step 4: Register commands in lib.rs**

Add to the `invoke_handler` list:

```rust
commands::get_djvu_page,
commands::get_djvu_page_count,
commands::get_djvu_page_text,
```

- [ ] **Step 5: Verify it compiles**

Run:
```bash
cd apps/main/src-tauri && cargo check
```
Expected: Compiles without errors.

- [ ] **Step 6: Commit**

```bash
git add apps/main/src-tauri/src/djvu.rs apps/main/src-tauri/src/commands.rs apps/main/src-tauri/src/lib.rs
git commit -m "feat: add DJVU page rendering and text extraction via ddjvu CLI"
```

---

### Task 5: Add DJVU TypeScript bindings

**Files:**
- Modify: `apps/main/src/generated/types.ts`
- Modify: `apps/main/src/generated/commands.ts`

- [ ] **Step 1: Add param types to types.ts**

Add to `apps/main/src/generated/types.ts`:

```typescript
export interface GetDjvuPageParams {
  path: Path;
  pageNumber: number;
  dpi: number;
  [key: string]: unknown;
}

export interface GetDjvuPageCountParams {
  path: Path;
  [key: string]: unknown;
}

export interface GetDjvuPageTextParams {
  path: Path;
  pageNumber: number;
  [key: string]: unknown;
}
```

- [ ] **Step 2: Add command functions to commands.ts**

Add to `apps/main/src/generated/commands.ts`:

```typescript
export async function getDjvuPage(params: types.GetDjvuPageParams): Promise<number[]> {
  return invoke('get_djvu_page', params);
}

export async function getDjvuPageCount(params: types.GetDjvuPageCountParams): Promise<number> {
  return invoke('get_djvu_page_count', params);
}

export async function getDjvuPageText(params: types.GetDjvuPageTextParams): Promise<string[]> {
  return invoke('get_djvu_page_text', params);
}
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/generated/types.ts apps/main/src/generated/commands.ts
git commit -m "feat: add DJVU page TypeScript bindings"
```

---

### Task 6: Create DjvuView component

**Files:**
- Create: `apps/main/src/components/djvu/DjvuView.tsx`

- [ ] **Step 1: Create DjvuView component**

Create `apps/main/src/components/djvu/DjvuView.tsx`:

```tsx
import React, { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { ChevronLeft, ChevronRight, ZoomIn, ZoomOut } from "lucide-react";
import { IconButton } from "@components/ui/IconButton";
import { getDjvuPage, getDjvuPageCount, updateBookLocation } from "@/generated";
import type { Book } from "@/generated";
import { BackButton } from "@components/BackButton";
import TTSControls from "@components/TTSControls";

const PAGE_CACHE_SIZE = 5;
const DEFAULT_DPI = 150;

export function DjvuView({ book }: { book: Book }) {
  const [pageNumber, setPageNumber] = useState(
    parseInt(book.location, 10) || 1
  );
  const [pageCount, setPageCount] = useState(0);
  const [zoom, setZoom] = useState(1.0);
  const [isLoading, setIsLoading] = useState(true);
  const [currentPageUrl, setCurrentPageUrl] = useState<string | null>(null);
  const pageCacheRef = useRef<Map<number, string>>(new Map());
  const scrollContainerRef = useRef<HTMLDivElement>(null);

  // Load page count on mount
  useEffect(() => {
    getDjvuPageCount({ path: book.filepath }).then((count) => {
      setPageCount(count);
    });
  }, [book.filepath]);

  // Convert raw PNG bytes (number[]) to a blob URL
  const bytesToBlobUrl = useCallback((bytes: number[]): string => {
    const uint8 = new Uint8Array(bytes);
    const blob = new Blob([uint8], { type: "image/png" });
    return URL.createObjectURL(blob);
  }, []);

  // Load page and manage cache
  useEffect(() => {
    if (pageCount === 0) return;

    const cache = pageCacheRef.current;

    // Check cache first
    if (cache.has(pageNumber)) {
      setCurrentPageUrl(cache.get(pageNumber)!);
      setIsLoading(false);
    } else {
      setIsLoading(true);
      getDjvuPage({ path: book.filepath, pageNumber, dpi: DEFAULT_DPI }).then(
        (bytes) => {
          const url = bytesToBlobUrl(bytes);

          // Evict oldest entries if cache is full
          if (cache.size >= PAGE_CACHE_SIZE) {
            const firstKey = cache.keys().next().value;
            if (firstKey !== undefined) {
              URL.revokeObjectURL(cache.get(firstKey)!);
              cache.delete(firstKey);
            }
          }

          cache.set(pageNumber, url);
          setCurrentPageUrl(url);
          setIsLoading(false);
        }
      );
    }

    // Prefetch adjacent pages
    const prefetchPage = (pg: number) => {
      if (pg >= 1 && pg <= pageCount && !cache.has(pg)) {
        getDjvuPage({ path: book.filepath, pageNumber: pg, dpi: DEFAULT_DPI }).then(
          (bytes) => {
            if (cache.size >= PAGE_CACHE_SIZE) {
              const firstKey = cache.keys().next().value;
              if (firstKey !== undefined) {
                URL.revokeObjectURL(cache.get(firstKey)!);
                cache.delete(firstKey);
              }
            }
            cache.set(pg, bytesToBlobUrl(bytes));
          }
        );
      }
    };

    prefetchPage(pageNumber + 1);
    prefetchPage(pageNumber - 1);

    // Persist reading position
    void updateBookLocation({ bookId: book.id, newLocation: String(pageNumber) });
  }, [pageNumber, pageCount, book.filepath, book.id, bytesToBlobUrl]);

  // Cleanup blob URLs on unmount
  useEffect(() => {
    const cache = pageCacheRef.current;
    return () => {
      for (const url of cache.values()) {
        URL.revokeObjectURL(url);
      }
      cache.clear();
    };
  }, []);

  const handlePrevPage = useCallback(() => {
    setPageNumber((prev) => Math.max(1, prev - 1));
  }, []);

  const handleNextPage = useCallback(() => {
    setPageNumber((prev) => Math.min(pageCount, prev + 1));
  }, [pageCount]);

  const handleZoomIn = useCallback(() => {
    setZoom((prev) => Math.min(3.0, prev + 0.25));
  }, []);

  const handleZoomOut = useCallback(() => {
    setZoom((prev) => Math.max(0.5, prev - 0.25));
  }, []);

  // Keyboard navigation
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "ArrowLeft") handlePrevPage();
      if (e.key === "ArrowRight") handleNextPage();
      if (e.key === "+" || e.key === "=") handleZoomIn();
      if (e.key === "-") handleZoomOut();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [handlePrevPage, handleNextPage, handleZoomIn, handleZoomOut]);

  return (
    <div className="relative bg-gray-900">
      {/* Top bar */}
      <div className="absolute right-2 top-2 z-10 flex items-center gap-2">
        <BackButton />
      </div>

      {/* Page content */}
      <div
        ref={scrollContainerRef}
        className="w-full h-screen overflow-auto flex justify-center items-start"
      >
        {isLoading ? (
          <div className="w-full h-full flex items-center justify-center">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-400" />
          </div>
        ) : currentPageUrl ? (
          <img
            src={currentPageUrl}
            alt={`Page ${pageNumber}`}
            className="max-w-full h-auto mt-4"
            style={{ transform: `scale(${zoom})`, transformOrigin: "top center" }}
          />
        ) : (
          <div className="text-white text-center mt-20">
            Failed to load page
          </div>
        )}
      </div>

      {/* Bottom navigation bar */}
      <div className="absolute bottom-20 left-1/2 -translate-x-1/2 z-10 flex items-center gap-3 px-4 py-2 bg-black/60 rounded-2xl backdrop-blur-lg">
        <IconButton
          onClick={handleZoomOut}
          className="text-white hover:bg-white/10"
        >
          <ZoomOut size={18} />
        </IconButton>
        <span className="text-white text-xs">{Math.round(zoom * 100)}%</span>
        <IconButton
          onClick={handleZoomIn}
          className="text-white hover:bg-white/10"
        >
          <ZoomIn size={18} />
        </IconButton>

        <div className="w-px h-5 bg-white/30" />

        <IconButton
          onClick={handlePrevPage}
          disabled={pageNumber <= 1}
          className="text-white hover:bg-white/10 disabled:text-white/30"
        >
          <ChevronLeft size={20} />
        </IconButton>
        <span className="text-white text-sm min-w-[80px] text-center">
          {pageNumber} / {pageCount}
        </span>
        <IconButton
          onClick={handleNextPage}
          disabled={pageNumber >= pageCount}
          className="text-white hover:bg-white/10 disabled:text-white/30"
        >
          <ChevronRight size={20} />
        </IconButton>
      </div>

      {/* TTS Controls */}
      <TTSControls bookId={book.id.toString()} />
    </div>
  );
}
```

- [ ] **Step 2: Commit**

```bash
git add apps/main/src/components/djvu/DjvuView.tsx
git commit -m "feat: add DjvuView page-image viewer component"
```

---

### Task 7: Wire viewers into book route

**Files:**
- Modify: `apps/main/src/routes/books.$id.lazy.tsx`

- [ ] **Step 1: Add imports for new viewers**

In `apps/main/src/routes/books.$id.lazy.tsx`, add imports at the top:

```typescript
import { MobiView } from "@components/mobi/MobiView";
import { DjvuView } from "@components/djvu/DjvuView";
```

- [ ] **Step 2: Replace placeholder routes with real viewers**

Replace the return JSX in `BookView` (lines 79-91) with:

```typescript
  return (
    <motion.div layout className="">
      {book?.kind === "pdf" && (
        <PdfView
          filepath={convertFileSrc(book.filepath)}
          key={book.id.toString()}
          book={book}
        />
      )}
      {book?.kind === "epub" && <EpubView key={book.id} book={book} />}
      {book?.kind === "mobi" && <MobiView key={book.id} book={book} />}
      {book?.kind === "djvu" && <DjvuView key={book.id} book={book} />}
    </motion.div>
  );
```

- [ ] **Step 3: Commit**

```bash
git add apps/main/src/routes/books.$id.lazy.tsx
git commit -m "feat: wire MobiView and DjvuView into book route"
```

---

### Task 8: End-to-end viewer test

**Files:** None (manual testing)

- [ ] **Step 1: Build and launch**

```bash
cd apps/main && npm run tauri dev
```

- [ ] **Step 2: Test MOBI reader**

1. Import a `.mobi` file
2. Open it — verify chapter content renders with the active theme
3. Navigate chapters with prev/next buttons and arrow keys
4. Change theme — verify it applies to the reader content
5. Close and reopen — verify reading position is restored

- [ ] **Step 3: Test DJVU reader**

1. Import a `.djvu` file (requires `ddjvu` and `djvused` installed: `brew install djvulibre`)
2. Open it — verify the first page renders as an image
3. Navigate pages with prev/next buttons and arrow keys
4. Zoom in/out with +/- keys
5. Close and reopen — verify reading position is restored

- [ ] **Step 4: Test DJVU graceful failure**

If `djvulibre` is not installed, verify:
1. DJVU files still import (metadata extraction uses the stub)
2. Opening the book shows a "Failed to load page" message (not a crash)

- [ ] **Step 5: Verify existing formats unaffected**

1. Open an existing EPUB — verify it works as before
2. Open an existing PDF — verify it works as before

- [ ] **Step 6: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during MOBI/DJVU viewer testing"
```
