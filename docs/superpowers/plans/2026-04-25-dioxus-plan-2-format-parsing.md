# Dioxus Desktop App — Plan 2: File Format Parsing + Text Extraction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `TextExtractor` trait and all 4 format parsers (EPUB, PDF, MOBI, DJVU) with text extraction, providing the foundation for TTS, AI/RAG, and search features.

**Architecture:** A `TextExtractor` trait with async methods, implemented by 4 format-specific structs. Each extracts paragraphs with optional position data. PDF uses PDFium for rendering + text. EPUB/MOBI parse HTML with `scraper`. DJVU shells out to `ddjvu` CLI.

**Tech Stack:** pdfium-render 0.9, epub 2.1, mobi 0.8, scraper 0.26, async-trait (for dyn dispatch), image 0.25

**Spec:** `docs/superpowers/specs/2026-04-25-dioxus-desktop-rewrite-design.md` (Text Extraction Pipeline section)

**Depends on:** Plan 1 (project scaffold + database)

---

## File Structure

```
apps/dioxus/src/formats/
├── mod.rs              — TextExtractor trait, Paragraph/PageContent types, format detection
├── epub.rs             — EpubExtractor: parse EPUB, extract chapter HTML + paragraphs
├── pdf.rs              — PdfExtractor: PDFium render + text extraction
├── mobi.rs             — MobiExtractor: parse MOBI, split chapters, extract paragraphs
└── djvu.rs             — DjvuExtractor: ddjvu CLI render + text extraction

apps/dioxus/tests/
├── db_test.rs          — (existing)
└── formats_test.rs     — integration tests for text extraction
```

---

### Task 1: Add format dependencies and create TextExtractor trait

**Files:**
- Modify: `apps/dioxus/Cargo.toml`
- Create: `apps/dioxus/src/formats/mod.rs`
- Modify: `apps/dioxus/src/lib.rs`

- [ ] **Step 1: Add dependencies to Cargo.toml**

Add to `[dependencies]` in `apps/dioxus/Cargo.toml`:

```toml
# File Formats
pdfium-render = { version = "0.9", features = ["image"] }
epub = "2.1"
mobi = "0.8"
scraper = "0.22"
image = "0.25"
async-trait = "0.1"
```

- [ ] **Step 2: Create the TextExtractor trait and types**

Create `apps/dioxus/src/formats/mod.rs`:

```rust
pub mod djvu;
pub mod epub;
pub mod mobi;
pub mod pdf;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// Position of a paragraph in the rendered content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ParagraphPosition {
    /// Pixel coordinates (PDF/DJVU) — top and bottom Y in points.
    Rect { left: f32, top: f32, right: f32, bottom: f32 },
    /// Index in the DOM/HTML (EPUB/MOBI).
    DomIndex(usize),
}

/// A single extracted paragraph.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Paragraph {
    pub index: usize,
    pub text: String,
    pub position: Option<ParagraphPosition>,
}

/// All paragraphs from a single page/chapter.
#[derive(Debug, Clone)]
pub struct PageContent {
    pub page_num: usize,
    pub paragraphs: Vec<Paragraph>,
}

/// Metadata extracted from a book file.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookMetadata {
    pub title: String,
    pub author: String,
    pub publisher: String,
    pub cover: Option<Vec<u8>>,
    pub format: BookFormat,
}

/// Supported book formats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BookFormat {
    Epub,
    Pdf,
    Mobi,
    Djvu,
}

impl BookFormat {
    /// Detect format from file extension.
    pub fn from_path(path: &str) -> Option<Self> {
        let lower = path.to_lowercase();
        if lower.ends_with(".epub") {
            Some(Self::Epub)
        } else if lower.ends_with(".pdf") {
            Some(Self::Pdf)
        } else if lower.ends_with(".mobi") || lower.ends_with(".azw3") || lower.ends_with(".azw") {
            Some(Self::Mobi)
        } else if lower.ends_with(".djvu") || lower.ends_with(".djv") {
            Some(Self::Djvu)
        } else {
            None
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Epub => "epub",
            Self::Pdf => "pdf",
            Self::Mobi => "mobi",
            Self::Djvu => "djvu",
        }
    }
}

/// Trait for extracting text and metadata from book files.
/// Uses async-trait for dyn dispatch compatibility.
#[async_trait]
pub trait TextExtractor: Send + Sync {
    /// Extract paragraphs from a single page/chapter.
    async fn extract_page(&self, page: usize) -> anyhow::Result<Vec<Paragraph>>;

    /// Extract all pages/chapters.
    async fn extract_all(&self) -> anyhow::Result<Vec<PageContent>>;

    /// Total number of pages/chapters.
    fn page_count(&self) -> usize;

    /// Extract book metadata (title, author, cover).
    fn metadata(&self) -> anyhow::Result<BookMetadata>;

    /// Get the raw content for rendering.
    /// For EPUB/MOBI: returns chapter HTML string.
    /// For PDF/DJVU: returns page image as PNG bytes.
    async fn render_page(&self, page: usize) -> anyhow::Result<Vec<u8>>;
}

/// Helper: extract paragraph text from an HTML string using scraper.
pub fn extract_paragraphs_from_html(html: &str) -> Vec<Paragraph> {
    let document = scraper::Html::parse_document(html);
    let selector = scraper::Selector::parse("p").unwrap();

    document
        .select(&selector)
        .enumerate()
        .map(|(index, el)| {
            let text: String = el.text().collect::<String>().trim().to_string();
            Paragraph {
                index,
                text,
                position: Some(ParagraphPosition::DomIndex(index)),
            }
        })
        .filter(|p| !p.text.is_empty())
        .collect()
}
```

- [ ] **Step 3: Add formats module to lib.rs**

Add `pub mod formats;` to `apps/dioxus/src/lib.rs`.

- [ ] **Step 4: Create empty stub files for format implementations**

Create `apps/dioxus/src/formats/epub.rs`:
```rust
// Implemented in Task 2
```

Create `apps/dioxus/src/formats/pdf.rs`:
```rust
// Implemented in Task 3
```

Create `apps/dioxus/src/formats/mobi.rs`:
```rust
// Implemented in Task 4
```

Create `apps/dioxus/src/formats/djvu.rs`:
```rust
// Implemented in Task 5
```

- [ ] **Step 5: Verify it compiles**

Run:
```bash
cd apps/dioxus && cargo check
```
Expected: Compiles (warnings about unused modules are fine).

- [ ] **Step 6: Commit**

```bash
git add apps/dioxus/
git commit -m "feat(dioxus): add TextExtractor trait and format types"
```

---

### Task 2: Implement EpubExtractor

**Files:**
- Modify: `apps/dioxus/src/formats/epub.rs`
- Create: `apps/dioxus/tests/formats_test.rs` (EPUB tests)

- [ ] **Step 1: Write the EPUB extraction test**

Create `apps/dioxus/tests/formats_test.rs`:

```rust
use rishi_dioxus::formats::{BookFormat, TextExtractor, extract_paragraphs_from_html};

#[test]
fn test_extract_paragraphs_from_html() {
    let html = r#"
        <html><body>
            <h1>Chapter Title</h1>
            <p>First paragraph with <em>emphasis</em>.</p>
            <p>Second paragraph.</p>
            <p>   </p>
            <p>Third paragraph after empty.</p>
        </body></html>
    "#;

    let paragraphs = extract_paragraphs_from_html(html);

    assert_eq!(paragraphs.len(), 3, "empty paragraphs should be filtered");
    assert_eq!(paragraphs[0].text, "First paragraph with emphasis.");
    assert_eq!(paragraphs[0].index, 0);
    assert_eq!(paragraphs[1].text, "Second paragraph.");
    assert_eq!(paragraphs[2].text, "Third paragraph after empty.");
}

#[test]
fn test_book_format_detection() {
    assert_eq!(BookFormat::from_path("/books/novel.epub"), Some(BookFormat::Epub));
    assert_eq!(BookFormat::from_path("/books/paper.pdf"), Some(BookFormat::Pdf));
    assert_eq!(BookFormat::from_path("/books/old.mobi"), Some(BookFormat::Mobi));
    assert_eq!(BookFormat::from_path("/books/old.azw3"), Some(BookFormat::Mobi));
    assert_eq!(BookFormat::from_path("/books/scan.djvu"), Some(BookFormat::Djvu));
    assert_eq!(BookFormat::from_path("/books/scan.djv"), Some(BookFormat::Djvu));
    assert_eq!(BookFormat::from_path("/books/notes.txt"), None);
    // Case insensitive
    assert_eq!(BookFormat::from_path("/books/NOVEL.EPUB"), Some(BookFormat::Epub));
}

#[test]
fn test_book_format_as_str() {
    assert_eq!(BookFormat::Epub.as_str(), "epub");
    assert_eq!(BookFormat::Pdf.as_str(), "pdf");
    assert_eq!(BookFormat::Mobi.as_str(), "mobi");
    assert_eq!(BookFormat::Djvu.as_str(), "djvu");
}
```

- [ ] **Step 2: Run test to verify it compiles and passes**

Run:
```bash
cd apps/dioxus && cargo test --test formats_test -- --test-threads=1
```
Expected: All 3 tests pass (these test the shared helpers, not EPUB-specific code yet).

- [ ] **Step 3: Implement EpubExtractor**

Replace `apps/dioxus/src/formats/epub.rs` with:

```rust
use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, TextExtractor,
    extract_paragraphs_from_html,
};
use async_trait::async_trait;
use epub::doc::EpubDoc;
use std::io::{Cursor, Read};
use std::path::PathBuf;
use std::sync::Mutex;

/// EPUB text extractor using the `epub` crate.
/// The EpubDoc is stateful (tracks current chapter), so we wrap in Mutex.
pub struct EpubExtractor {
    path: PathBuf,
    doc: Mutex<EpubDoc<Cursor<Vec<u8>>>>,
    num_chapters: usize,
}

impl EpubExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();
        let doc = EpubDoc::new(&path)
            .map_err(|e| anyhow::anyhow!("Failed to open EPUB '{}': {}", path.display(), e))?;
        let num_chapters = doc.get_num_chapters();
        Ok(Self {
            path,
            doc: Mutex::new(doc),
            num_chapters,
        })
    }

    /// Get the HTML content of a specific chapter.
    pub fn get_chapter_html(&self, chapter: usize) -> anyhow::Result<String> {
        let mut doc = self.doc.lock().map_err(|e| anyhow::anyhow!("Lock poisoned: {}", e))?;
        doc.set_current_chapter(chapter);
        doc.get_current_str()
            .map(|(html, _mime)| html)
            .ok_or_else(|| anyhow::anyhow!("Failed to get chapter {} content", chapter))
    }
}

#[async_trait]
impl TextExtractor for EpubExtractor {
    async fn extract_page(&self, page: usize) -> anyhow::Result<Vec<Paragraph>> {
        let html = self.get_chapter_html(page)?;
        Ok(extract_paragraphs_from_html(&html))
    }

    async fn extract_all(&self) -> anyhow::Result<Vec<PageContent>> {
        let mut pages = Vec::with_capacity(self.num_chapters);
        for i in 0..self.num_chapters {
            let paragraphs = self.extract_page(i).await?;
            pages.push(PageContent {
                page_num: i,
                paragraphs,
            });
        }
        Ok(pages)
    }

    fn page_count(&self) -> usize {
        self.num_chapters
    }

    fn metadata(&self) -> anyhow::Result<BookMetadata> {
        let mut doc = self.doc.lock().map_err(|e| anyhow::anyhow!("Lock poisoned: {}", e))?;

        let title = doc.mdata("title")
            .map(|m| m.value.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let author = doc.mdata("creator")
            .map(|m| m.value.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let publisher = doc.mdata("publisher")
            .map(|m| m.value.clone())
            .unwrap_or_default();
        let cover = doc.get_cover();

        Ok(BookMetadata {
            title,
            author,
            publisher,
            cover,
            format: BookFormat::Epub,
        })
    }

    async fn render_page(&self, page: usize) -> anyhow::Result<Vec<u8>> {
        // For EPUB, "rendering" means returning the chapter HTML as bytes.
        let html = self.get_chapter_html(page)?;
        Ok(html.into_bytes())
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run:
```bash
cd apps/dioxus && cargo check
```
Expected: Compiles.

- [ ] **Step 5: Commit**

```bash
git add apps/dioxus/
git commit -m "feat(dioxus): implement EpubExtractor with chapter HTML + paragraph extraction"
```

---

### Task 3: Implement PdfExtractor

**Files:**
- Modify: `apps/dioxus/src/formats/pdf.rs`

- [ ] **Step 1: Implement PdfExtractor**

Replace `apps/dioxus/src/formats/pdf.rs` with:

```rust
use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, ParagraphPosition, TextExtractor,
};
use async_trait::async_trait;
use pdfium_render::prelude::*;
use std::path::PathBuf;
use std::sync::Mutex;

/// PDF text extractor using PDFium.
pub struct PdfExtractor {
    path: PathBuf,
    pdfium: Pdfium,
    page_count: usize,
}

impl PdfExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();

        // Try to load PDFium library from default locations
        let pdfium = Pdfium::default();

        // Open document to get page count
        let document = pdfium.load_pdf_from_file(&path, None)
            .map_err(|e| anyhow::anyhow!("Failed to open PDF '{}': {:?}", path.display(), e))?;
        let page_count = document.pages().len();

        Ok(Self {
            path,
            pdfium,
            page_count,
        })
    }

    /// Open the document (needed per-operation since PdfDocument borrows Pdfium).
    fn open_doc(&self) -> anyhow::Result<PdfDocument> {
        self.pdfium
            .load_pdf_from_file(&self.path, None)
            .map_err(|e| anyhow::anyhow!("Failed to open PDF: {:?}", e))
    }

    /// Extract text segments from a page and cluster into paragraphs by Y-gap.
    fn extract_page_text(&self, page_index: usize) -> anyhow::Result<Vec<Paragraph>> {
        let document = self.open_doc()?;
        let page = document.pages().get(page_index as u16)
            .map_err(|e| anyhow::anyhow!("Failed to get page {}: {:?}", page_index, e))?;

        let text_page = page.text()
            .map_err(|e| anyhow::anyhow!("Failed to get text for page {}: {:?}", page_index, e))?;

        // Collect text segments with their bounding boxes
        let mut segments: Vec<(String, PdfRect)> = Vec::new();
        for segment in text_page.segments().iter() {
            let content = segment.text();
            if content.trim().is_empty() {
                continue;
            }
            if let Ok(bounds) = segment.bounds() {
                segments.push((content, bounds));
            }
        }

        // Sort by Y position (top of page = higher value in PDF coords)
        segments.sort_by(|a, b| b.1.top.partial_cmp(&a.1.top).unwrap_or(std::cmp::Ordering::Equal));

        // Cluster segments into paragraphs based on Y-gap threshold
        let mut paragraphs: Vec<Paragraph> = Vec::new();
        let mut current_text = String::new();
        let mut current_bounds: Option<PdfRect> = None;
        let y_gap_threshold = 5.0; // points

        for (text, bounds) in &segments {
            if let Some(prev_bounds) = &current_bounds {
                let gap = prev_bounds.bottom.value - bounds.top.value;
                if gap.abs() > y_gap_threshold {
                    // New paragraph
                    if !current_text.trim().is_empty() {
                        let pb = prev_bounds;
                        paragraphs.push(Paragraph {
                            index: paragraphs.len(),
                            text: current_text.trim().to_string(),
                            position: Some(ParagraphPosition::Rect {
                                left: pb.left.value,
                                top: pb.top.value,
                                right: pb.right.value,
                                bottom: pb.bottom.value,
                            }),
                        });
                    }
                    current_text = text.clone();
                    current_bounds = Some(*bounds);
                } else {
                    // Same paragraph — append
                    current_text.push(' ');
                    current_text.push_str(text);
                    // Expand bounds
                    let mut expanded = *prev_bounds;
                    if bounds.left < expanded.left {
                        expanded.left = bounds.left;
                    }
                    if bounds.right > expanded.right {
                        expanded.right = bounds.right;
                    }
                    if bounds.bottom < expanded.bottom {
                        expanded.bottom = bounds.bottom;
                    }
                    current_bounds = Some(expanded);
                }
            } else {
                current_text = text.clone();
                current_bounds = Some(*bounds);
            }
        }

        // Flush last paragraph
        if !current_text.trim().is_empty() {
            if let Some(pb) = &current_bounds {
                paragraphs.push(Paragraph {
                    index: paragraphs.len(),
                    text: current_text.trim().to_string(),
                    position: Some(ParagraphPosition::Rect {
                        left: pb.left.value,
                        top: pb.top.value,
                        right: pb.right.value,
                        bottom: pb.bottom.value,
                    }),
                });
            }
        }

        Ok(paragraphs)
    }
}

#[async_trait]
impl TextExtractor for PdfExtractor {
    async fn extract_page(&self, page: usize) -> anyhow::Result<Vec<Paragraph>> {
        self.extract_page_text(page)
    }

    async fn extract_all(&self) -> anyhow::Result<Vec<PageContent>> {
        let mut pages = Vec::with_capacity(self.page_count);
        for i in 0..self.page_count {
            let paragraphs = self.extract_page_text(i)?;
            pages.push(PageContent {
                page_num: i,
                paragraphs,
            });
        }
        Ok(pages)
    }

    fn page_count(&self) -> usize {
        self.page_count
    }

    fn metadata(&self) -> anyhow::Result<BookMetadata> {
        let document = self.open_doc()?;
        let metadata = document.metadata();

        let title = metadata.title().unwrap_or_else(|| "Unknown".to_string());
        let author = metadata.author().unwrap_or_else(|| "Unknown".to_string());
        let publisher = metadata.creator().unwrap_or_default();

        // PDF doesn't have a standard "cover" — use first page render as fallback
        Ok(BookMetadata {
            title,
            author,
            publisher,
            cover: None,
            format: BookFormat::Pdf,
        })
    }

    async fn render_page(&self, page: usize) -> anyhow::Result<Vec<u8>> {
        let document = self.open_doc()?;
        let page = document.pages().get(page as u16)
            .map_err(|e| anyhow::anyhow!("Failed to get page {}: {:?}", page, e))?;

        let render_config = PdfRenderConfig::new()
            .set_target_width(1600)
            .set_maximum_height(2400);

        let bitmap = page.render_with_config(&render_config)
            .map_err(|e| anyhow::anyhow!("Failed to render page: {:?}", e))?;

        // Convert to PNG bytes
        let img = bitmap.as_image();
        let mut png_bytes: Vec<u8> = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut png_bytes);
        img.write_to(&mut cursor, image::ImageFormat::Png)
            .map_err(|e| anyhow::anyhow!("Failed to encode PNG: {}", e))?;

        Ok(png_bytes)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd apps/dioxus && cargo check
```
Expected: Compiles. (PDFium library not needed for compile check, only at runtime.)

- [ ] **Step 3: Commit**

```bash
git add apps/dioxus/
git commit -m "feat(dioxus): implement PdfExtractor with PDFium rendering + text extraction"
```

---

### Task 4: Implement MobiExtractor

**Files:**
- Modify: `apps/dioxus/src/formats/mobi.rs`

- [ ] **Step 1: Implement MobiExtractor**

Replace `apps/dioxus/src/formats/mobi.rs` with:

```rust
use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, TextExtractor,
    extract_paragraphs_from_html,
};
use async_trait::async_trait;
use std::path::PathBuf;

/// MOBI text extractor using the `mobi` crate.
/// Splits the single HTML content into chapters at `<mbp:pagebreak>` markers.
pub struct MobiExtractor {
    path: PathBuf,
    chapters: Vec<String>,
    title: String,
    author: String,
    cover: Option<Vec<u8>>,
}

impl MobiExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();
        let m = mobi::Mobi::from_path(&path)
            .map_err(|e| anyhow::anyhow!("Failed to open MOBI '{}': {:?}", path.display(), e))?;

        let title = m.title();
        let author = m.author().unwrap_or_else(|| "Unknown".to_string());

        // Get cover from first image record
        let cover = m.image_records().first().map(|r| r.content.to_vec());

        // Get full HTML content and split into chapters
        let content = m.content_as_string_lossy();
        let chapters = split_mobi_chapters(&content);

        Ok(Self {
            path,
            chapters,
            title,
            author,
            cover,
        })
    }
}

/// Split MOBI HTML content into chapters at `<mbp:pagebreak>` markers.
/// Falls back to treating the entire content as one chapter.
fn split_mobi_chapters(html: &str) -> Vec<String> {
    // MOBI uses <mbp:pagebreak/> or <mbp:pagebreak /> to separate chapters
    let parts: Vec<&str> = html.split("<mbp:pagebreak").collect();

    if parts.len() <= 1 {
        // No page breaks found — try splitting at <h1> or <h2> tags
        let parts: Vec<&str> = html.split("<h1").collect();
        if parts.len() <= 1 {
            return vec![html.to_string()];
        }
        return parts
            .into_iter()
            .enumerate()
            .map(|(i, part)| {
                if i == 0 && part.trim().is_empty() {
                    return String::new();
                }
                if i > 0 {
                    format!("<h1{}", part)
                } else {
                    part.to_string()
                }
            })
            .filter(|s| !s.trim().is_empty())
            .collect();
    }

    parts
        .into_iter()
        .map(|part| {
            // Strip the closing /> or > from the pagebreak tag
            if let Some(rest) = part.strip_prefix("/>") {
                rest.to_string()
            } else if let Some(rest) = part.strip_prefix(" />") {
                rest.to_string()
            } else if let Some(rest) = part.strip_prefix(">") {
                rest.to_string()
            } else {
                part.to_string()
            }
        })
        .filter(|s| !s.trim().is_empty())
        .collect()
}

#[async_trait]
impl TextExtractor for MobiExtractor {
    async fn extract_page(&self, page: usize) -> anyhow::Result<Vec<Paragraph>> {
        let html = self.chapters.get(page)
            .ok_or_else(|| anyhow::anyhow!("Chapter {} out of range (total: {})", page, self.chapters.len()))?;
        Ok(extract_paragraphs_from_html(html))
    }

    async fn extract_all(&self) -> anyhow::Result<Vec<PageContent>> {
        let mut pages = Vec::with_capacity(self.chapters.len());
        for (i, chapter) in self.chapters.iter().enumerate() {
            let paragraphs = extract_paragraphs_from_html(chapter);
            pages.push(PageContent {
                page_num: i,
                paragraphs,
            });
        }
        Ok(pages)
    }

    fn page_count(&self) -> usize {
        self.chapters.len()
    }

    fn metadata(&self) -> anyhow::Result<BookMetadata> {
        Ok(BookMetadata {
            title: self.title.clone(),
            author: self.author.clone(),
            publisher: String::new(),
            cover: self.cover.clone(),
            format: BookFormat::Mobi,
        })
    }

    async fn render_page(&self, page: usize) -> anyhow::Result<Vec<u8>> {
        // For MOBI, "rendering" means returning the chapter HTML as bytes.
        let html = self.chapters.get(page)
            .ok_or_else(|| anyhow::anyhow!("Chapter {} out of range", page))?;
        Ok(html.as_bytes().to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_mobi_chapters_with_pagebreaks() {
        let html = "Chapter 1 content<mbp:pagebreak/>Chapter 2 content<mbp:pagebreak />Chapter 3";
        let chapters = split_mobi_chapters(html);
        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0], "Chapter 1 content");
        assert!(chapters[1].contains("Chapter 2 content"));
        assert!(chapters[2].contains("Chapter 3"));
    }

    #[test]
    fn test_split_mobi_chapters_no_breaks() {
        let html = "<p>Just one big chapter</p>";
        let chapters = split_mobi_chapters(html);
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0], html);
    }
}
```

- [ ] **Step 2: Run tests**

Run:
```bash
cd apps/dioxus && cargo test -- --test-threads=1
```
Expected: All existing + new tests pass.

- [ ] **Step 3: Commit**

```bash
git add apps/dioxus/
git commit -m "feat(dioxus): implement MobiExtractor with chapter splitting + paragraph extraction"
```

---

### Task 5: Implement DjvuExtractor

**Files:**
- Modify: `apps/dioxus/src/formats/djvu.rs`

- [ ] **Step 1: Implement DjvuExtractor**

Replace `apps/dioxus/src/formats/djvu.rs` with:

```rust
use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, ParagraphPosition, TextExtractor,
};
use async_trait::async_trait;
use std::path::PathBuf;
use std::process::Command;

/// DJVU text extractor using the `ddjvu` CLI tool.
pub struct DjvuExtractor {
    path: PathBuf,
    page_count: usize,
}

impl DjvuExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();

        // Validate DJVU magic bytes (AT&T)
        let file_bytes = std::fs::read(&path)?;
        if file_bytes.len() < 4 || &file_bytes[0..4] != b"AT&T" {
            anyhow::bail!("Not a valid DJVU file: {}", path.display());
        }

        // Get page count via djvused
        let page_count = get_djvu_page_count(&path)?;

        Ok(Self { path, page_count })
    }
}

/// Get the number of pages in a DJVU file using djvused.
fn get_djvu_page_count(path: &PathBuf) -> anyhow::Result<usize> {
    let output = Command::new("djvused")
        .arg(path)
        .arg("-e")
        .arg("n")
        .output()
        .map_err(|e| anyhow::anyhow!("Failed to run djvused (is it installed?): {}", e))?;

    if !output.status.success() {
        anyhow::bail!(
            "djvused failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let count_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
    count_str
        .parse::<usize>()
        .map_err(|e| anyhow::anyhow!("Failed to parse page count '{}': {}", count_str, e))
}

/// Extract text from a DJVU page using ddjvu.
fn get_djvu_page_text(path: &PathBuf, page: usize) -> anyhow::Result<String> {
    let output = Command::new("ddjvu")
        .arg("-format=utf8")
        .arg(format!("-page={}", page + 1)) // ddjvu uses 1-based page numbers
        .arg(path)
        .arg("-")
        .output()
        .map_err(|e| anyhow::anyhow!("Failed to run ddjvu: {}", e))?;

    if !output.status.success() {
        // ddjvu may fail for pages without text layer — return empty
        return Ok(String::new());
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Render a DJVU page to PNG using ddjvu.
fn render_djvu_page(path: &PathBuf, page: usize, dpi: u32) -> anyhow::Result<Vec<u8>> {
    let temp_path = std::env::temp_dir().join(format!("rishi_djvu_{}_{}.ppm", std::process::id(), page));

    let status = Command::new("ddjvu")
        .arg(format!("-format=ppm"))
        .arg(format!("-page={}", page + 1))
        .arg(format!("-size={}x{}", dpi * 8, dpi * 11)) // approximate letter size
        .arg(path)
        .arg(&temp_path)
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to run ddjvu: {}", e))?;

    if !status.success() {
        anyhow::bail!("ddjvu rendering failed for page {}", page);
    }

    // Read the PPM file and convert to PNG
    let ppm_data = std::fs::read(&temp_path)?;
    let _ = std::fs::remove_file(&temp_path); // cleanup

    // Load PPM and convert to PNG bytes
    let img = image::load_from_memory(&ppm_data)
        .map_err(|e| anyhow::anyhow!("Failed to decode PPM: {}", e))?;
    let mut png_bytes: Vec<u8> = Vec::new();
    let mut cursor = std::io::Cursor::new(&mut png_bytes);
    img.write_to(&mut cursor, image::ImageFormat::Png)
        .map_err(|e| anyhow::anyhow!("Failed to encode PNG: {}", e))?;

    Ok(png_bytes)
}

#[async_trait]
impl TextExtractor for DjvuExtractor {
    async fn extract_page(&self, page: usize) -> anyhow::Result<Vec<Paragraph>> {
        let text = get_djvu_page_text(&self.path, page)?;
        if text.trim().is_empty() {
            return Ok(Vec::new());
        }

        // Split text into paragraphs by double newlines or single newlines
        let paragraphs: Vec<Paragraph> = text
            .split("\n\n")
            .enumerate()
            .map(|(index, para)| {
                let cleaned = para.lines().collect::<Vec<_>>().join(" ").trim().to_string();
                Paragraph {
                    index,
                    text: cleaned,
                    position: None, // ddjvu text output doesn't include coordinates
                }
            })
            .filter(|p| !p.text.is_empty())
            .collect();

        Ok(paragraphs)
    }

    async fn extract_all(&self) -> anyhow::Result<Vec<PageContent>> {
        let mut pages = Vec::with_capacity(self.page_count);
        for i in 0..self.page_count {
            let paragraphs = self.extract_page(i).await?;
            pages.push(PageContent {
                page_num: i,
                paragraphs,
            });
        }
        Ok(pages)
    }

    fn page_count(&self) -> usize {
        self.page_count
    }

    fn metadata(&self) -> anyhow::Result<BookMetadata> {
        // DJVU doesn't have rich metadata — use filename as title
        let title = self
            .path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown")
            .to_string();

        Ok(BookMetadata {
            title,
            author: "Unknown".to_string(),
            publisher: String::new(),
            cover: None,
            format: BookFormat::Djvu,
        })
    }

    async fn render_page(&self, page: usize) -> anyhow::Result<Vec<u8>> {
        render_djvu_page(&self.path, page, 150) // 150 DPI default
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
cd apps/dioxus && cargo check
```
Expected: Compiles.

- [ ] **Step 3: Commit**

```bash
git add apps/dioxus/
git commit -m "feat(dioxus): implement DjvuExtractor with ddjvu CLI rendering + text extraction"
```

---

### Task 6: Final verification and clippy

- [ ] **Step 1: Run all tests**

Run:
```bash
cd apps/dioxus && cargo test -- --test-threads=1
```
Expected: All tests pass (db_test + formats_test + mobi unit tests).

- [ ] **Step 2: Run clippy**

Run:
```bash
cd apps/dioxus && cargo clippy -- -D warnings
```
Expected: No warnings. Fix any that arise.

- [ ] **Step 3: Commit any fixes**

```bash
git add apps/dioxus/
git commit -m "fix(dioxus): address clippy warnings in format extractors"
```
