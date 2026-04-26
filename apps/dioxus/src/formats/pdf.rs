use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, ParagraphPosition, TextExtractor,
};
use async_trait::async_trait;
use pdfium_render::prelude::*;
use std::path::PathBuf;

/// PDF text extractor using PDFium.
///
/// Note: PDFium must be available as a shared library at runtime.
/// `Pdfium::default()` attempts to load it from the current directory
/// or the system library path. If not found, construction will panic.
pub struct PdfExtractor {
    path: PathBuf,
    pdfium: Pdfium,
    page_count: usize,
}

impl PdfExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();

        // Try to load PDFium library from default locations.
        // This will panic if PDFium is not installed -- that is acceptable
        // for now since PDFium is a runtime dependency.
        // Note: Pdfium is a unit struct with thread_safe, but Default::default()
        // has the side effect of loading the shared library.
        #[allow(clippy::default_constructed_unit_structs)]
        let pdfium = Pdfium::default();

        // Open document to get page count, then drop it before moving pdfium.
        let page_count = {
            let document = pdfium
                .load_pdf_from_file(&path, None)
                .map_err(|e| {
                    anyhow::anyhow!("Failed to open PDF '{}': {:?}", path.display(), e)
                })?;
            document.pages().len() as usize
        };

        Ok(Self {
            path,
            pdfium,
            page_count,
        })
    }

    /// Open the document (needed per-operation since PdfDocument borrows Pdfium).
    fn open_doc(&self) -> anyhow::Result<PdfDocument<'_>> {
        self.pdfium
            .load_pdf_from_file(&self.path, None)
            .map_err(|e| anyhow::anyhow!("Failed to open PDF: {:?}", e))
    }

    /// Extract text segments from a page and cluster into paragraphs by Y-gap.
    fn extract_page_text(&self, page_index: usize) -> anyhow::Result<Vec<Paragraph>> {
        let document = self.open_doc()?;
        let page = document
            .pages()
            .get(page_index as PdfPageIndex)
            .map_err(|e| anyhow::anyhow!("Failed to get page {}: {:?}", page_index, e))?;

        let text_page = page
            .text()
            .map_err(|e| anyhow::anyhow!("Failed to get text for page {}: {:?}", page_index, e))?;

        // Collect text segments with their bounding boxes.
        let mut segments: Vec<(String, PdfRect)> = Vec::new();
        for segment in text_page.segments().iter() {
            let content = segment.text();
            if content.trim().is_empty() {
                continue;
            }
            let bounds = segment.bounds();
            segments.push((content, bounds));
        }

        // Sort by Y position (top of page = higher value in PDF coords).
        // Process top-to-bottom, so sort descending by top.
        segments.sort_by(|a, b| {
            b.1.top()
                .value
                .partial_cmp(&a.1.top().value)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Cluster segments into paragraphs based on Y-gap threshold.
        let mut paragraphs: Vec<Paragraph> = Vec::new();
        let mut current_text = String::new();
        let mut current_top: Option<f32> = None;
        let mut current_bottom: Option<f32> = None;
        let mut current_left: Option<f32> = None;
        let mut current_right: Option<f32> = None;
        let y_gap_threshold = 5.0; // points

        for (text, bounds) in &segments {
            let seg_top = bounds.top().value;
            let seg_bottom = bounds.bottom().value;
            let seg_left = bounds.left().value;
            let seg_right = bounds.right().value;

            if let Some(prev_bottom) = current_bottom {
                let gap = (prev_bottom - seg_top).abs();
                if gap > y_gap_threshold {
                    // New paragraph -- flush current.
                    if !current_text.trim().is_empty() {
                        paragraphs.push(Paragraph {
                            index: paragraphs.len(),
                            text: current_text.trim().to_string(),
                            position: Some(ParagraphPosition::Rect {
                                left: current_left.unwrap_or(0.0),
                                top: current_top.unwrap_or(0.0),
                                right: current_right.unwrap_or(0.0),
                                bottom: prev_bottom,
                            }),
                        });
                    }
                    current_text = text.clone();
                    current_top = Some(seg_top);
                    current_bottom = Some(seg_bottom);
                    current_left = Some(seg_left);
                    current_right = Some(seg_right);
                } else {
                    // Same paragraph -- append.
                    current_text.push(' ');
                    current_text.push_str(text);
                    if seg_left < current_left.unwrap_or(f32::MAX) {
                        current_left = Some(seg_left);
                    }
                    if seg_right > current_right.unwrap_or(f32::MIN) {
                        current_right = Some(seg_right);
                    }
                    current_bottom = Some(seg_bottom);
                }
            } else {
                current_text = text.clone();
                current_top = Some(seg_top);
                current_bottom = Some(seg_bottom);
                current_left = Some(seg_left);
                current_right = Some(seg_right);
            }
        }

        // Flush last paragraph.
        if !current_text.trim().is_empty() {
            paragraphs.push(Paragraph {
                index: paragraphs.len(),
                text: current_text.trim().to_string(),
                position: Some(ParagraphPosition::Rect {
                    left: current_left.unwrap_or(0.0),
                    top: current_top.unwrap_or(0.0),
                    right: current_right.unwrap_or(0.0),
                    bottom: current_bottom.unwrap_or(0.0),
                }),
            });
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

        let title = metadata
            .get(PdfDocumentMetadataTagType::Title)
            .map(|t| t.value().to_string())
            .unwrap_or_else(|| "Unknown".to_string());
        let author = metadata
            .get(PdfDocumentMetadataTagType::Author)
            .map(|t| t.value().to_string())
            .unwrap_or_else(|| "Unknown".to_string());
        let publisher = metadata
            .get(PdfDocumentMetadataTagType::Creator)
            .map(|t| t.value().to_string())
            .unwrap_or_default();

        // PDF doesn't have a standard "cover" -- use first page render as fallback.
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
        let page = document
            .pages()
            .get(page as PdfPageIndex)
            .map_err(|e| anyhow::anyhow!("Failed to get page: {:?}", e))?;

        let render_config = PdfRenderConfig::new()
            .set_target_width(1600)
            .set_maximum_height(2400);

        let bitmap = page
            .render_with_config(&render_config)
            .map_err(|e| anyhow::anyhow!("Failed to render page: {:?}", e))?;

        // Convert to PNG bytes.
        let img = bitmap
            .as_image()
            .map_err(|e| anyhow::anyhow!("Failed to convert bitmap to image: {:?}", e))?;
        let mut png_bytes: Vec<u8> = Vec::new();
        let mut cursor = std::io::Cursor::new(&mut png_bytes);
        img.write_to(&mut cursor, image::ImageFormat::Png)
            .map_err(|e| anyhow::anyhow!("Failed to encode PNG: {}", e))?;

        Ok(png_bytes)
    }
}
