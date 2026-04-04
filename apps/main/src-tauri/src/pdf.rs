use std::{
    fmt::Display,
    path::{Path, PathBuf},
};

use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};
use pdf::file::FileOptions;

pub enum Cover {
    #[allow(dead_code)]
    Normal(Vec<u8>),
    Fallback(Vec<u8>),
}

pub struct Pdf {
    path: PathBuf,
}
impl Pdf {
    pub fn new(path: &Path) -> Self {
        Pdf {
            path: path.to_path_buf(),
        }
    }
}
impl Extractable for Pdf {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>> {
        let path = &self.path;

        if !path.exists() {
            return Err(format!("File not found: {}", path.display()).into());
        }

        // Open PDF with lazy loading using pdf crate
        let file = &FileOptions::cached().open(path)?;

        // Info dictionary is optional in PDFs - extract metadata if available
        let title = file
            .trailer
            .info_dict
            .as_ref()
            .and_then(|dict| dict.title.as_ref())
            .and_then(|s| s.to_string().ok());
        let author = file
            .trailer
            .info_dict
            .as_ref()
            .and_then(|dict| dict.author.as_ref())
            .and_then(|s| s.to_string().ok());
        let publisher = file
            .trailer
            .info_dict
            .as_ref()
            .and_then(|dict| dict.creator.as_ref())
            .and_then(|s| s.to_string().ok());
        let cover = create_placeholder_cover()?;
        let pdf_path = path.to_str().unwrap_or_default().to_string();
        let digest = md5::compute(path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let kind = BookKind::Pdf.to_string();
        let current_location = "1".to_string();
        let cover_kind = Some(cover.to_string());

        match cover {
            Cover::Fallback(cover) => Ok(BookData::new(
                id,
                kind,
                cover,
                title,
                author,
                publisher,
                pdf_path,
                current_location,
                cover_kind,
            )),
            Cover::Normal(cover) => Ok(BookData::new(
                id,
                kind,
                cover,
                title,
                author,
                publisher,
                pdf_path,
                current_location,
                cover_kind,
            )),
        }
    }
}

impl Display for Cover {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Cover::Normal(_) => write!(f, "normal"),
            Cover::Fallback(_) => write!(f, "fallback"),
        }
    }
}

fn create_placeholder_cover() -> Result<Cover, Box<dyn std::error::Error>> {
    use image::{ImageFormat, Rgba, RgbaImage};
    use std::io::Cursor;

    // Create a book-like placeholder cover (400x600 - typical book aspect ratio)
    let width = 400u32;
    let height = 600u32;

    // Create a more book-like background with a subtle pattern
    let mut img = RgbaImage::new(width, height);

    for (x, y, pixel) in img.enumerate_pixels_mut() {
        // Create a subtle book-like texture
        let gradient_y = (y as f32 / height as f32).min(1.0);
        let _gradient_x = (x as f32 / width as f32).min(1.0);

        // Base colors for a book cover look
        let base_r = 45u8;
        let base_g = 55u8;
        let base_b = 70u8;

        // Add some texture and variation
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

    // Add a simple "PDF" text area in the center
    let text_area_y = height / 2 - 40;
    let text_area_height = 80;
    let text_area_x = width / 4;
    let text_area_width = width / 2;

    // Create a lighter rectangle for text area
    for y in text_area_y..(text_area_y + text_area_height).min(height) {
        for x in text_area_x..(text_area_x + text_area_width).min(width) {
            let pixel = img.get_pixel_mut(x, y);
            *pixel = Rgba([200, 210, 220, 255]);
        }
    }

    // Add a simple border around the text area
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

    // Encode as PNG
    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image::DynamicImage::ImageRgba8(img).write_to(&mut cursor, ImageFormat::Png)?;

    Ok(Cover::Fallback(buffer))
}
