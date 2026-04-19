use base64::{engine::general_purpose::STANDARD, Engine};
use log::info;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffResult {
    pub baseline_path: String,
    pub actual_path: String,
    pub diff_path: Option<String>,
    pub match_percentage: f64,
    pub dimensions: (u32, u32),
    pub diff_pixel_count: u64,
    pub passed: bool,
    pub threshold: f64,
}

/// Save a base64 PNG screenshot to disk
pub fn save_screenshot(base64_data: &str, folder: &str, name: &str) -> Result<String, String> {
    let folder_path = Path::new(folder);
    std::fs::create_dir_all(folder_path)
        .map_err(|e| format!("Failed to create folder: {}", e))?;

    // Strip data URL prefix if present
    let raw = if let Some(stripped) = base64_data.strip_prefix("data:image/png;base64,") {
        stripped
    } else {
        base64_data
    };

    let bytes = STANDARD
        .decode(raw)
        .map_err(|e| format!("Invalid base64: {}", e))?;
    let file_path = folder_path.join(format!("{}.png", name));
    std::fs::write(&file_path, &bytes).map_err(|e| format!("Failed to write: {}", e))?;
    info!("Saved screenshot: {}", file_path.display());
    Ok(file_path.to_string_lossy().to_string())
}

/// Load a screenshot from disk as base64
pub fn load_screenshot(path: &str) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("Failed to read {}: {}", path, e))?;
    Ok(format!(
        "data:image/png;base64,{}",
        STANDARD.encode(&bytes)
    ))
}

/// Compare two PNG images pixel-by-pixel, generate a diff image
pub fn diff_screenshots(
    baseline_path: &str,
    actual_base64: &str,
    diff_folder: &str,
    name: &str,
    threshold: f64,
) -> Result<DiffResult, String> {
    let baseline_bytes =
        std::fs::read(baseline_path).map_err(|e| format!("Baseline read failed: {}", e))?;

    let raw = if let Some(stripped) = actual_base64.strip_prefix("data:image/png;base64,") {
        stripped
    } else {
        actual_base64
    };
    let actual_bytes = STANDARD
        .decode(raw)
        .map_err(|e| format!("Invalid base64: {}", e))?;

    // Decode PNGs
    let baseline_img =
        image::load_from_memory_with_format(&baseline_bytes, image::ImageFormat::Png)
            .map_err(|e| format!("Baseline decode failed: {}", e))?
            .to_rgba8();
    let actual_img = image::load_from_memory_with_format(&actual_bytes, image::ImageFormat::Png)
        .map_err(|e| format!("Actual decode failed: {}", e))?
        .to_rgba8();

    let (w, h) = baseline_img.dimensions();
    let (aw, ah) = actual_img.dimensions();

    // Use the larger dimensions
    let max_w = w.max(aw);
    let max_h = h.max(ah);
    let total_pixels = (max_w as u64) * (max_h as u64);

    let mut diff_img = image::RgbaImage::new(max_w, max_h);
    let mut diff_count: u64 = 0;

    for y in 0..max_h {
        for x in 0..max_w {
            let bp = if x < w && y < h {
                *baseline_img.get_pixel(x, y)
            } else {
                image::Rgba([0, 0, 0, 0])
            };
            let ap = if x < aw && y < ah {
                *actual_img.get_pixel(x, y)
            } else {
                image::Rgba([0, 0, 0, 0])
            };

            if bp != ap {
                diff_count += 1;
                // Red highlight for differences
                diff_img.put_pixel(x, y, image::Rgba([255, 0, 0, 200]));
            } else {
                // Dimmed original for matching pixels
                diff_img.put_pixel(x, y, image::Rgba([bp[0] / 3, bp[1] / 3, bp[2] / 3, 128]));
            }
        }
    }

    let match_pct = if total_pixels > 0 {
        1.0 - (diff_count as f64 / total_pixels as f64)
    } else {
        1.0
    };

    let passed = match_pct >= threshold;

    // Save diff image
    std::fs::create_dir_all(diff_folder)
        .map_err(|e| format!("Failed to create diff folder: {}", e))?;
    let diff_path = PathBuf::from(diff_folder).join(format!("{}.diff.png", name));
    diff_img
        .save(&diff_path)
        .map_err(|e| format!("Failed to save diff: {}", e))?;

    // Also save the actual screenshot
    let actual_folder = PathBuf::from(diff_folder).join("actual");
    std::fs::create_dir_all(&actual_folder).map_err(|e| e.to_string())?;
    let actual_path = actual_folder.join(format!("{}.png", name));
    std::fs::write(&actual_path, &actual_bytes).map_err(|e| e.to_string())?;

    Ok(DiffResult {
        baseline_path: baseline_path.to_string(),
        actual_path: actual_path.to_string_lossy().to_string(),
        diff_path: Some(diff_path.to_string_lossy().to_string()),
        match_percentage: match_pct,
        dimensions: (max_w, max_h),
        diff_pixel_count: diff_count,
        passed,
        threshold,
    })
}

/// Check if a baseline exists for a given name
pub fn has_baseline(folder: &str, name: &str) -> bool {
    Path::new(folder).join(format!("{}.png", name)).exists()
}

/// Get the baseline path for a given name
pub fn baseline_path(folder: &str, name: &str) -> PathBuf {
    Path::new(folder).join(format!("{}.png", name))
}
