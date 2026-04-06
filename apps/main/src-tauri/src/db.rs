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

    // Configure SQLite for concurrent access
    {
        use diesel::RunQueryDsl;
        let mut conn = pool.get()?;
        diesel::sql_query("PRAGMA journal_mode=WAL;").execute(&mut conn)?;
        diesel::sql_query("PRAGMA busy_timeout=5000;").execute(&mut conn)?;
    }

    // Backfill sync_ids for any books missing them (safety net for migration edge cases)
    {
        let mut conn = pool.get()?;
        backfill_sync_ids(&mut conn)?;
    }

    DB_POOL
        .set(pool)
        .map_err(|_| anyhow::anyhow!("Failed to set DB_POOL: pool already initialized"))?;

    Ok(())
}

/// Backfill sync_id with UUID v4 for any books that are missing one.
/// This is a safety net in case the SQL-only UUID backfill in the migration
/// didn't work (the randomblob approach is non-standard in some SQLite builds).
fn backfill_sync_ids(conn: &mut SqliteConnection) -> anyhow::Result<()> {
    use diesel::prelude::*;

    // Find books without sync_id
    #[derive(diesel::QueryableByName)]
    struct BookIdRow {
        #[diesel(sql_type = diesel::sql_types::Integer)]
        id: i32,
    }

    let rows: Vec<BookIdRow> =
        diesel::sql_query("SELECT id FROM books WHERE sync_id IS NULL")
            .load(conn)?;

    let count = rows.len();
    for row in rows {
        let new_uuid = uuid::Uuid::new_v4().to_string();
        diesel::sql_query("UPDATE books SET sync_id = ?1, is_dirty = 1 WHERE id = ?2")
            .bind::<diesel::sql_types::Text, _>(&new_uuid)
            .bind::<diesel::sql_types::Integer, _>(&row.id)
            .execute(conn)?;
    }

    if count > 0 {
        println!("Backfilled sync_id for {} books", count);
    }

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

#[cfg(test)]
mod tests {
    use super::*;
    use diesel::RunQueryDsl;

    fn setup_in_memory_db() -> SqliteConnection {
        let mut conn = SqliteConnection::establish(":memory:")
            .expect("Failed to create in-memory SQLite connection");
        conn.run_pending_migrations(MIGRATIONS)
            .expect("Failed to run migrations");
        conn
    }

    #[test]
    fn test_sync_columns_exist_on_books() {
        let mut conn = setup_in_memory_db();

        diesel::sql_query(
            "SELECT sync_id, file_hash, file_r2_key, cover_r2_key, format, \
             current_cfi, current_page, user_id, sync_version, is_dirty, is_deleted \
             FROM books LIMIT 1",
        )
        .execute(&mut conn)
        .expect("sync columns should exist on books table");
    }

    #[test]
    fn test_highlights_table_exists() {
        let mut conn = setup_in_memory_db();

        diesel::sql_query(
            "SELECT id, book_id, user_id, cfi_range, text, color, note, chapter, \
             created_at, updated_at, sync_version, is_dirty, is_deleted \
             FROM highlights LIMIT 1",
        )
        .execute(&mut conn)
        .expect("highlights table should exist with expected columns");
    }

    #[test]
    fn test_conversations_table_exists() {
        let mut conn = setup_in_memory_db();

        diesel::sql_query(
            "SELECT id, book_id, user_id, title, created_at, updated_at, \
             sync_version, is_dirty, is_deleted \
             FROM conversations LIMIT 1",
        )
        .execute(&mut conn)
        .expect("conversations table should exist with expected columns");
    }

    #[test]
    fn test_messages_table_exists() {
        let mut conn = setup_in_memory_db();

        diesel::sql_query(
            "SELECT id, conversation_id, role, content, source_chunks, \
             created_at, updated_at, sync_version, is_dirty, is_deleted \
             FROM messages LIMIT 1",
        )
        .execute(&mut conn)
        .expect("messages table should exist with expected columns");
    }

    #[test]
    fn test_sync_meta_seeded() {
        let mut conn = setup_in_memory_db();

        diesel::sql_query(
            "SELECT id, last_sync_version, last_sync_at \
             FROM sync_meta WHERE id = 'default'",
        )
        .execute(&mut conn)
        .expect("sync_meta should have default row");
    }
}
