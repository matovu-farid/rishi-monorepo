use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use epub::doc::EpubDoc;

use std::path::{Path, PathBuf};

pub struct Epub {
    pub path: PathBuf,
}
impl Epub {
    pub fn new(path: &Path) -> Self {
        Epub {
            path: path.to_path_buf(),
        }
    }
}
impl Extractable for Epub {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let epub_path = &self.path;
        let mut doc = EpubDoc::new(epub_path).map_err(|e| e.to_string())?;

        // Try to get cover; fall back to placeholder if unavailable
        let (cover, cover_kind) = match doc.get_cover() {
            Some(cover_data) => (cover_data.0, None),
            None => {
                eprintln!(
                    "[epub] No cover found for '{}', using placeholder",
                    epub_path.display()
                );
                (create_placeholder_cover(), Some("fallback".to_string()))
            }
        };

        let title = doc.get_title();

        let author = doc.mdata("creator").map(|data| data.value.clone());
        let publisher = doc.mdata("publisher").map(|data| data.value.clone());
        // create a unique id by hashing the path
        let digest = md5::compute(epub_path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = epub_path.to_string_lossy().to_string();
        let kind = BookKind::Epub.to_string();
        let current_location = "".to_string();

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
    if let Err(e) =
        image::DynamicImage::ImageRgba8(img).write_to(&mut cursor, ImageFormat::Png)
    {
        eprintln!("[epub] Failed to encode placeholder cover: {}", e);
        return Vec::new();
    }

    buffer
}
