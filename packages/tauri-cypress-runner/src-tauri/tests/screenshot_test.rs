use tauri_cypress_runner::screenshot;

/// Minimal valid 1x1 red PNG in base64
const RED_1X1_PNG: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";

/// Minimal valid 1x1 blue PNG in base64
const BLUE_1X1_PNG: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";

#[test]
fn test_save_and_load_screenshot() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().to_str().unwrap();

    let saved_path = screenshot::save_screenshot(RED_1X1_PNG, folder, "test_shot").unwrap();
    assert!(std::path::Path::new(&saved_path).exists());

    let loaded = screenshot::load_screenshot(&saved_path).unwrap();
    // load_screenshot returns a data URL, strip the prefix to compare raw base64
    let loaded_b64 = loaded.strip_prefix("data:image/png;base64,").unwrap();
    assert_eq!(loaded_b64, RED_1X1_PNG);
}

#[test]
fn test_save_screenshot_creates_directory() {
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("a").join("b").join("c");
    let folder = nested.to_str().unwrap();

    let saved_path = screenshot::save_screenshot(RED_1X1_PNG, folder, "deep").unwrap();
    assert!(std::path::Path::new(&saved_path).exists());
}

#[test]
fn test_save_screenshot_strips_data_url_prefix() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().to_str().unwrap();

    let data_url = format!("data:image/png;base64,{}", RED_1X1_PNG);
    let saved_path = screenshot::save_screenshot(&data_url, folder, "prefixed").unwrap();
    assert!(std::path::Path::new(&saved_path).exists());

    // Verify the saved content matches what we get from saving without the prefix
    let loaded = screenshot::load_screenshot(&saved_path).unwrap();
    let loaded_b64 = loaded.strip_prefix("data:image/png;base64,").unwrap();
    assert_eq!(loaded_b64, RED_1X1_PNG);
}

#[test]
fn test_diff_identical_images() {
    let dir = tempfile::tempdir().unwrap();
    let baseline_folder = dir.path().join("baseline");
    let diff_folder = dir.path().join("diffs");
    let baseline_dir = baseline_folder.to_str().unwrap();
    let diff_dir = diff_folder.to_str().unwrap();

    // Save a baseline
    let baseline_path =
        screenshot::save_screenshot(RED_1X1_PNG, baseline_dir, "identical").unwrap();

    // Diff with the same image
    let result =
        screenshot::diff_screenshots(&baseline_path, RED_1X1_PNG, diff_dir, "identical", 0.99)
            .unwrap();

    assert_eq!(result.match_percentage, 1.0);
    assert_eq!(result.diff_pixel_count, 0);
    assert!(result.passed);
    assert_eq!(result.dimensions, (1, 1));
}

#[test]
fn test_diff_different_images() {
    let dir = tempfile::tempdir().unwrap();
    let baseline_folder = dir.path().join("baseline");
    let diff_folder = dir.path().join("diffs");
    let baseline_dir = baseline_folder.to_str().unwrap();
    let diff_dir = diff_folder.to_str().unwrap();

    // Save a red baseline
    let baseline_path =
        screenshot::save_screenshot(RED_1X1_PNG, baseline_dir, "different").unwrap();

    // Diff with a blue image
    let result =
        screenshot::diff_screenshots(&baseline_path, BLUE_1X1_PNG, diff_dir, "different", 0.99)
            .unwrap();

    assert!(result.match_percentage < 1.0);
    assert!(result.diff_pixel_count > 0);
    assert!(!result.passed);
    // A diff image should have been created
    assert!(result.diff_path.is_some());
    assert!(std::path::Path::new(result.diff_path.as_ref().unwrap()).exists());
}

#[test]
fn test_has_baseline() {
    let dir = tempfile::tempdir().unwrap();
    let folder = dir.path().to_str().unwrap();

    // Before saving, baseline should not exist
    assert!(!screenshot::has_baseline(folder, "shot"));

    // Save, then it should exist
    screenshot::save_screenshot(RED_1X1_PNG, folder, "shot").unwrap();
    assert!(screenshot::has_baseline(folder, "shot"));

    // Non-existent name still returns false
    assert!(!screenshot::has_baseline(folder, "nonexistent"));
}

#[test]
fn test_baseline_path() {
    let path = screenshot::baseline_path("/screenshots/baseline", "my_test");
    assert_eq!(
        path,
        std::path::PathBuf::from("/screenshots/baseline/my_test.png")
    );
}
