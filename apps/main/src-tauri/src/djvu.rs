use std::path::{Path, PathBuf};

use crate::shared::{
    books::Extractable,
    types::{BookData, BookKind},
};

pub struct Djvu {
    path: PathBuf,
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
        let path = &self.path;

        if !path.exists() {
            return Err(format!("File not found: {}", path.display()).into());
        }

        // Validate DJVU magic bytes: file must start with "AT&T"
        let file_bytes = std::fs::read(path)?;
        if file_bytes.len() < 4 || &file_bytes[..4] != b"AT&T" {
            return Err(format!(
                "Not a valid DJVU file (missing AT&T magic bytes): {}",
                path.display()
            )
            .into());
        }

        // Derive title from filename (strip extension)
        let title = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string());

        let cover = create_placeholder_cover();

        let digest = md5::compute(path.to_string_lossy().to_string());
        let id = format!("{:x}", digest);
        let file_path = path.to_string_lossy().to_string();
        let kind = BookKind::Djvu.to_string();
        let current_location = "1".to_string();
        let cover_kind = Some("fallback".to_string());

        Ok(BookData::new(
            id,
            kind,
            cover,
            title,
            None,      // author
            None,      // publisher
            file_path,
            current_location,
            cover_kind,
        ))
    }
}

/// Render a single DJVU page to PNG bytes using the `ddjvu` CLI tool.
pub fn render_page_to_png(
    path: &Path,
    page: u32,
    dpi: u32,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    use image::ImageFormat;
    use std::io::Cursor;

    let width = dpi * 8;
    let height = dpi * 11;

    let tmp_dir = std::env::temp_dir();
    let tmp_file = tmp_dir.join(format!("rishi_djvu_{}_{}.ppm", std::process::id(), page));

    let output = std::process::Command::new("ddjvu")
        .arg("-format=ppm")
        .arg(format!("-page={}", page))
        .arg(format!("-size={}x{}", width, height))
        .arg(path.as_os_str())
        .arg(tmp_file.as_os_str())
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let _ = std::fs::remove_file(&tmp_file);
        return Err(format!("ddjvu failed: {}", stderr).into());
    }

    let ppm_data = std::fs::read(&tmp_file)?;
    let _ = std::fs::remove_file(&tmp_file);

    let img = image::load_from_memory_with_format(&ppm_data, ImageFormat::Pnm)?;
    let mut png_buf = Vec::new();
    img.write_to(&mut Cursor::new(&mut png_buf), ImageFormat::Png)?;

    Ok(png_buf)
}

/// Get the total page count of a DJVU file using `djvused`.
pub fn get_page_count(path: &Path) -> Result<u32, Box<dyn std::error::Error>> {
    let output = std::process::Command::new("djvused")
        .arg(path.as_os_str())
        .arg("-e")
        .arg("n")
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("djvused failed: {}", stderr).into());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let count: u32 = stdout.trim().parse()?;
    Ok(count)
}

/// Extract text from a single DJVU page using `djvutxt`.
pub fn get_page_text(
    path: &Path,
    page: u32,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let output = std::process::Command::new("djvutxt")
        .arg(format!("--page={}", page))
        .arg(path.as_os_str())
        .output()?;

    if !output.status.success() {
        // No text layer or tool failure — return empty
        return Ok(Vec::new());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let paragraphs: Vec<String> = stdout
        .lines()
        .map(|l| l.to_string())
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
