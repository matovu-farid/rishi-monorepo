use super::{
    BookFormat, BookMetadata, PageContent, Paragraph, TextExtractor,
};
use async_trait::async_trait;
use std::path::PathBuf;
use std::process::Command;

/// DJVU text extractor using the `ddjvu` CLI tool.
///
/// Requires `djvused` and `ddjvu` to be installed and available on PATH.
/// On macOS: `brew install djvulibre`
/// On Ubuntu: `apt-get install djvulibre-bin`
pub struct DjvuExtractor {
    path: PathBuf,
    page_count: usize,
}

impl DjvuExtractor {
    pub fn new(path: impl Into<PathBuf>) -> anyhow::Result<Self> {
        let path = path.into();

        // Validate DJVU magic bytes (AT&T).
        let file_bytes = std::fs::read(&path)?;
        if file_bytes.len() < 4 || &file_bytes[0..4] != b"AT&T" {
            anyhow::bail!("Not a valid DJVU file: {}", path.display());
        }

        // Get page count via djvused.
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
        // ddjvu may fail for pages without text layer -- return empty.
        return Ok(String::new());
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Render a DJVU page to PNG using ddjvu.
fn render_djvu_page(path: &PathBuf, page: usize, dpi: u32) -> anyhow::Result<Vec<u8>> {
    let temp_path = std::env::temp_dir().join(format!(
        "rishi_djvu_{}_{}.ppm",
        std::process::id(),
        page
    ));

    let status = Command::new("ddjvu")
        .arg("-format=ppm")
        .arg(format!("-page={}", page + 1))
        .arg(format!("-size={}x{}", dpi * 8, dpi * 11)) // approximate letter size
        .arg(path)
        .arg(&temp_path)
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to run ddjvu: {}", e))?;

    if !status.success() {
        anyhow::bail!("ddjvu rendering failed for page {}", page);
    }

    // Read the PPM file and convert to PNG.
    let ppm_data = std::fs::read(&temp_path)?;
    let _ = std::fs::remove_file(&temp_path); // cleanup

    // Load PPM and convert to PNG bytes.
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

        // Split text into paragraphs by double newlines.
        let paragraphs: Vec<Paragraph> = text
            .split("\n\n")
            .enumerate()
            .map(|(index, para)| {
                let cleaned = para
                    .lines()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .trim()
                    .to_string();
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
        // DJVU doesn't have rich metadata -- use filename as title.
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
