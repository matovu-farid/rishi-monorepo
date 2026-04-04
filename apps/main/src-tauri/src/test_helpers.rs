// Test helpers for database initialization and setup

use std::path::PathBuf;
use tempfile::TempDir;

use crate::db;

/// Test database setup result containing both the temporary directory
/// and the app data directory path for use in tests
#[allow(dead_code)]
pub struct TestDatabaseSetup {
    /// Temporary directory that will be cleaned up when dropped
    pub temp_dir: TempDir,
    /// Path to the app data directory (same as temp_dir.path())
    pub app_data_dir: PathBuf,
    /// Path to the test database file
    pub db_path: PathBuf,
}

impl TestDatabaseSetup {
    /// Get the database path as a string
    #[allow(dead_code)]
    pub fn db_path_str(&self) -> &str {
        self.db_path
            .to_str()
            .expect("Failed to convert path to string")
    }
}

/// Initialize a test database in a temporary directory.
/// Returns a `TestDatabaseSetup` struct that contains the temporary directory
/// and paths needed for testing. The temporary directory is automatically
/// cleaned up when the struct is dropped.
///
/// # Example
/// ```
/// use crate::test_helpers::init_test_database_setup;
///
/// let setup = init_test_database_setup()?;
/// let db_path = setup.db_path_str();
/// // Use db_path and setup.app_data_dir in your tests
/// ```
pub fn init_test_database_setup() -> Result<TestDatabaseSetup, String> {
    let temp_dir = TempDir::new().map_err(|e| format!("Failed to create temp directory: {}", e))?;
    let app_data_dir = temp_dir.path().to_path_buf();
    let db_path = app_data_dir.join("test_rishi.db");

    db::init_test_database(db_path.to_str().ok_or("Failed to convert path to string")?)
        .map_err(|e| format!("Failed to initialize test database: {}", e))?;

    Ok(TestDatabaseSetup {
        temp_dir,
        app_data_dir,
        db_path,
    })
}
