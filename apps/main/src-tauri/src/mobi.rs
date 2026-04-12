use std::path::{Path, PathBuf};

use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};

pub struct Mobi {
    path: PathBuf,
}

impl Mobi {
    pub fn new(path: &Path) -> Self {
        Mobi {
            path: path.to_path_buf(),
        }
    }
}

impl Extractable for Mobi {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let path = &self.path;

        if !path.exists() {
            return Err(format!("File not found: {}", path.display()).into());
        }

        let m = mobi::Mobi::from_path(path)?;

        let title = {
            let t = m.title();
            if t.is_empty() { None } else { Some(t) }
        };
        let author = m.author();
        let publisher = m.publisher();

        // Try to extract cover from image records, fall back to placeholder
        let cover = extract_cover(&m).unwrap_or_else(|| create_placeholder_cover());

        let digest = md5::compute(path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = path.to_string_lossy().to_string();
        let kind = BookKind::Mobi.to_string();
        let current_location = "0".to_string();
        let cover_kind = Some("fallback".to_string());

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            author,
            publisher,
            file_path,
            current_location,
            cover_kind,
        ))
    }
}

/// Try to extract the first image record as a cover image.
fn extract_cover(m: &mobi::Mobi) -> Option<Vec<u8>> {
    let image_records = m.image_records();
    let first = image_records.first()?;
    if first.content.is_empty() {
        return None;
    }
    Some(first.content.to_vec())
}

/// Strip HTML tags from a string, returning plain text.
fn strip_html_tags(html: &str) -> String {
    let mut result = String::with_capacity(html.len());
    let mut inside_tag = false;
    for ch in html.chars() {
        match ch {
            '<' => inside_tag = true,
            '>' => inside_tag = false,
            _ if !inside_tag => result.push(ch),
            _ => {}
        }
    }
    result
}

/// Parse a MOBI file and split its HTML content into chapters by `<mbp:pagebreak/>` markers.
pub fn get_chapters(path: &Path) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let m = mobi::Mobi::from_path(path)?;
    let content = m.content_as_string_lossy();

    let chapters: Vec<String> = content
        .split("<mbp:pagebreak/>")
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    if chapters.is_empty() {
        Ok(vec![content])
    } else {
        Ok(chapters)
    }
}

/// Return the HTML content of a single chapter by index.
pub fn get_chapter(path: &Path, chapter_index: u32) -> Result<String, Box<dyn std::error::Error>> {
    let chapters = get_chapters(path)?;
    let idx = chapter_index as usize;
    if idx >= chapters.len() {
        return Err(format!(
            "Chapter index {} out of range (total {})",
            chapter_index,
            chapters.len()
        )
        .into());
    }
    Ok(chapters[idx].clone())
}

/// Return the number of chapters in a MOBI file.
pub fn get_chapter_count(path: &Path) -> Result<u32, Box<dyn std::error::Error>> {
    let chapters = get_chapters(path)?;
    Ok(chapters.len() as u32)
}

/// Return the plain-text paragraphs of a single chapter.
pub fn get_chapter_text(
    path: &Path,
    chapter_index: u32,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let html = get_chapter(path, chapter_index)?;
    let plain = strip_html_tags(&html);
    let paragraphs: Vec<String> = plain
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect();
    Ok(paragraphs)
}

fn create_placeholder_cover() -> Vec<u8> {
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    let width = 400u32;
    let height = 600u32;
    let mut img = RgbaImage::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        let gradient_y = (y as f32 / height as f32).min(1.0);

        let base_r = 45u8;
        let base_g = 55u8;
        let base_b = 70u8;

        let noise = ((x + y) % 7) as u8 * 3;
        let edge_darken = if x < 20 || x > width - 20 || y < 20 || y > height - 20 {
            20
        } else {
            0
        };

        *pixel = Rgba([
            (base_r + (gradient_y * 30.0) as u8 + noise).saturating_sub(edge_darken),
            (base_g + (gradient_y * 35.0) as u8 + noise).saturating_sub(edge_darken),
            (base_b + (gradient_y * 40.0) as u8 + noise).saturating_sub(edge_darken),
            255,
        ]);
    }

    let text_area_y = height / 2 - 40;
    let text_area_height = 80;
    let text_area_x = width / 4;
    let text_area_width = width / 2;

    for y in text_area_y..(text_area_y + text_area_height).min(height) {
        for x in text_area_x..(text_area_x + text_area_width).min(width) {
            let pixel = img.get_pixel_mut(x, y);
            *pixel = Rgba([200, 210, 220, 255]);
        }
    }

    for y in text_area_y..(text_area_y + text_area_height).min(height) {
        for x in [text_area_x, text_area_x + text_area_width - 1] {
            if x < width {
                let pixel = img.get_pixel_mut(x, y);
                *pixel = Rgba([100, 110, 120, 255]);
            }
        }
    }
    for x in text_area_x..(text_area_x + text_area_width).min(width) {
        for y in [text_area_y, text_area_y + text_area_height - 1] {
            if y < height {
                let pixel = img.get_pixel_mut(x, y);
                *pixel = Rgba([100, 110, 120, 255]);
            }
        }
    }

    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image::DynamicImage::ImageRgba8(img)
        .write_to(&mut cursor, ImageFormat::Png)
        .expect("Failed to encode placeholder cover");

    buffer
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn strip_html_tags_basic() {
        assert_eq!(strip_html_tags("<p>hello</p>"), "hello");
    }

    #[test]
    fn strip_html_tags_nested() {
        assert_eq!(strip_html_tags("<div><span>text</span></div>"), "text");
    }

    #[test]
    fn strip_html_tags_empty() {
        assert_eq!(strip_html_tags(""), "");
    }

    #[test]
    fn strip_html_tags_no_tags() {
        assert_eq!(strip_html_tags("plain text"), "plain text");
    }

    #[test]
    fn strip_html_tags_with_attributes() {
        assert_eq!(strip_html_tags(r#"<a href="url">link</a>"#), "link");
    }

    #[test]
    fn placeholder_cover_is_non_empty_png() {
        let cover = create_placeholder_cover();
        assert!(!cover.is_empty(), "Placeholder cover should not be empty");
        // PNG magic bytes: 0x89 P N G
        assert_eq!(
            &cover[..4],
            &[137, 80, 78, 71],
            "Placeholder cover should start with PNG magic bytes"
        );
    }

    #[test]
    fn get_chapters_invalid_path_returns_error() {
        let bad_path = PathBuf::from("/nonexistent/fake.mobi");
        let result = get_chapters(&bad_path);
        assert!(result.is_err(), "get_chapters with invalid path should error");
    }

    #[test]
    fn get_chapter_invalid_path_returns_error() {
        let bad_path = PathBuf::from("/nonexistent/fake.mobi");
        let result = get_chapter(&bad_path, 0);
        assert!(result.is_err(), "get_chapter with invalid path should error");
    }

    #[test]
    fn get_chapter_count_invalid_path_returns_error() {
        let bad_path = PathBuf::from("/nonexistent/fake.mobi");
        let result = get_chapter_count(&bad_path);
        assert!(result.is_err());
    }

    #[test]
    fn extract_nonexistent_file_returns_error() {
        let bad_path = PathBuf::from("/nonexistent/fake.mobi");
        let mobi = Mobi::new(&bad_path);
        let result = mobi.extract();
        assert!(result.is_err());
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("File not found"),
            "Expected 'File not found' error, got: {}",
            err_msg
        );
    }
}
