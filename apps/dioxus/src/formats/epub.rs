use super::{
    extract_paragraphs_from_html, BookFormat, BookMetadata, PageContent, Paragraph, TextExtractor,
};
use async_trait::async_trait;
use epub::doc::EpubDoc;
use std::fs::File;
use std::io::BufReader;
use std::path::PathBuf;
use std::sync::Mutex;

/// EPUB text extractor using the `epub` crate.
/// The EpubDoc is stateful (tracks current chapter), so we wrap in Mutex.
pub struct EpubExtractor {
    #[allow(dead_code)]
    path: PathBuf,
    doc: Mutex<EpubDoc<BufReader<File>>>,
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
        let mut doc = self
            .doc
            .lock()
            .map_err(|e| anyhow::anyhow!("Lock poisoned: {}", e))?;
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
        let mut doc = self
            .doc
            .lock()
            .map_err(|e| anyhow::anyhow!("Lock poisoned: {}", e))?;

        let title = doc
            .mdata("title")
            .map(|m| m.value.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let author = doc
            .mdata("creator")
            .map(|m| m.value.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let publisher = doc
            .mdata("publisher")
            .map(|m| m.value.clone())
            .unwrap_or_default();
        let cover = doc.get_cover().map(|(data, _mime)| data);

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
