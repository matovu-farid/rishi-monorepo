use super::{
    extract_paragraphs_from_html, BookFormat, BookMetadata, PageContent, Paragraph, TextExtractor,
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

        // Get cover from first image record.
        let cover = m.image_records().first().map(|r| r.content.to_vec());

        // Get full HTML content and split into chapters.
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
    // MOBI uses <mbp:pagebreak/> or <mbp:pagebreak /> to separate chapters.
    let parts: Vec<&str> = html.split("<mbp:pagebreak").collect();

    if parts.len() <= 1 {
        // No page breaks found -- try splitting at <h1> tags.
        let h1_parts: Vec<&str> = html.split("<h1").collect();
        if h1_parts.len() <= 1 {
            return vec![html.to_string()];
        }
        return h1_parts
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
            // Strip the closing /> or > from the pagebreak tag.
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
        let html = self.chapters.get(page).ok_or_else(|| {
            anyhow::anyhow!(
                "Chapter {} out of range (total: {})",
                page,
                self.chapters.len()
            )
        })?;
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
        let html = self
            .chapters
            .get(page)
            .ok_or_else(|| anyhow::anyhow!("Chapter {} out of range", page))?;
        Ok(html.as_bytes().to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_mobi_chapters_with_pagebreaks() {
        let html =
            "Chapter 1 content<mbp:pagebreak/>Chapter 2 content<mbp:pagebreak />Chapter 3";
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

    #[test]
    fn test_split_mobi_chapters_with_h1_fallback() {
        let html = "<h1>Chapter 1</h1><p>content 1</p><h1>Chapter 2</h1><p>content 2</p>";
        let chapters = split_mobi_chapters(html);
        assert_eq!(chapters.len(), 2);
        assert!(chapters[0].starts_with("<h1"));
        assert!(chapters[1].starts_with("<h1"));
    }
}
