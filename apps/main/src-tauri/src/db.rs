use diesel::sqlite::SqliteConnection;
use diesel::Connection;
use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use std::path::PathBuf;
use tauri::Manager;

use diesel::r2d2::ConnectionManager;
use r2d2::Pool;
use std::sync::OnceLock;

pub static DB_POOL: OnceLock<Pool<ConnectionManager<SqliteConnection>>> = OnceLock::new();

const MIGRATIONS: EmbeddedMigrations = embed_migrations!();

pub fn init_database(app: &tauri::AppHandle) -> anyhow::Result<String> {
    // 1. Get app data directory (per-user!)
    let mut db_path: PathBuf = app
        .path()
        .app_data_dir()
        .expect("failed to get app data dir");

    // 2. Ensure directory exists
    std::fs::create_dir_all(&db_path)?;

    // 3. Name the SQLite file
    db_path.push("rishi.db");

    // 4. Convert to string path Diesel expects
    let conn_url = db_path.to_string_lossy().to_string();

    // 5. Connect to SQLite (this creates file if missing)
    let mut conn = SqliteConnection::establish(&conn_url).expect("Failed to connect to SQLite DB");

    // 6. Run pending Diesel migrations (creates schema on first run)
    conn.run_pending_migrations(MIGRATIONS)
        .expect("Failed to run migrations");

    println!("Database initialized at {}", conn_url);

    Ok(conn_url)
}

pub fn setup_database(app: &tauri::AppHandle) -> anyhow::Result<()> {
    let conn_url = init_database(app)?;
    let manager = diesel::r2d2::ConnectionManager::<SqliteConnection>::new(conn_url);

    // Configure connection pool with reasonable defaults
    let pool = Pool::builder()
        .max_size(10) // Maximum number of connections in the pool
        .min_idle(Some(2)) // Minimum number of idle connections to maintain
        .connection_timeout(std::time::Duration::from_secs(30)) // Timeout for getting a connection
        .build(manager)?;

    DB_POOL
        .set(pool)
        .map_err(|_| anyhow::anyhow!("Failed to set DB_POOL: pool already initialized"))?;

    Ok(())
}

pub fn init_test_database(db_path: &str) -> anyhow::Result<()> {
    use std::fs;

    // Ensure parent directory exists
    if let Some(parent) = std::path::Path::new(db_path).parent() {
        fs::create_dir_all(parent)?;
    }

    // Connect to SQLite (this creates file if missing)
    let mut conn = SqliteConnection::establish(db_path)
        .map_err(|e| anyhow::anyhow!("Failed to connect to SQLite DB: {}", e))?;

    // Run pending Diesel migrations (creates schema on first run)
    conn.run_pending_migrations(MIGRATIONS)
        .map_err(|e| anyhow::anyhow!("Failed to run migrations: {}", e))?;

    // Create connection pool
    let manager = diesel::r2d2::ConnectionManager::<SqliteConnection>::new(db_path);
    let pool = Pool::builder()
        .max_size(10)
        .min_idle(Some(2))
        .connection_timeout(std::time::Duration::from_secs(30))
        .build(manager)
        .map_err(|e| anyhow::anyhow!("Failed to create connection pool: {}", e))?;

    // Set the pool (ignore if already set - allows multiple tests to call this)
    let _ = DB_POOL.set(pool);

    Ok(())
}
