pub mod djvu;
pub mod epub;
pub mod mobi;
pub mod pdf;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

/// Position of a paragraph in the rendered content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ParagraphPosition {
    /// Pixel coordinates (PDF/DJVU) -- top and bottom Y in points.
    Rect {
        left: f32,
        top: f32,
        right: f32,
        bottom: f32,
    },
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
