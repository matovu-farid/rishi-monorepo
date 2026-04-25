use diesel::prelude::*;
use diesel::r2d2::ConnectionManager;
use diesel::sqlite::SqliteConnection;
use diesel_migrations::{embed_migrations, EmbeddedMigrations, MigrationHarness};
use r2d2::Pool;
use std::sync::OnceLock;

pub const MIGRATIONS: EmbeddedMigrations = embed_migrations!();

pub type DbPool = Pool<ConnectionManager<SqliteConnection>>;

pub static DB_POOL: OnceLock<DbPool> = OnceLock::new();

/// Customizer that runs PRAGMA statements on every new SQLite connection
/// acquired from the pool.
#[derive(Debug)]
struct SqlitePragmaCustomizer;

impl r2d2::CustomizeConnection<SqliteConnection, diesel::r2d2::Error>
    for SqlitePragmaCustomizer
{
    fn on_acquire(
        &self,
        conn: &mut SqliteConnection,
    ) -> Result<(), diesel::r2d2::Error> {
        use diesel::RunQueryDsl;
        diesel::sql_query("PRAGMA busy_timeout=5000;")
            .execute(conn)
            .map_err(diesel::r2d2::Error::QueryError)?;
        diesel::sql_query("PRAGMA journal_mode=WAL;")
            .execute(conn)
            .map_err(diesel::r2d2::Error::QueryError)?;
        Ok(())
    }
}

/// Get a connection from the global pool.
pub fn get_conn() -> Result<r2d2::PooledConnection<ConnectionManager<SqliteConnection>>, String> {
    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    pool.get().map_err(|e| {
        eprintln!("[db] Connection pool exhausted: {}", e);
        format!("Database connection unavailable: {}", e)
    })
}

/// Resolve the database file path using the system data directory.
fn db_path() -> std::path::PathBuf {
    let mut path = dirs::data_dir().expect("could not determine data directory");
    path.push("org.fidexa.rishi");
    std::fs::create_dir_all(&path).expect("could not create app data directory");
    path.push("rishi.db");
    path
}

/// Initialize the database: run migrations, build pool, backfill, store global.
pub fn setup_database() -> anyhow::Result<()> {
    let db = db_path();
    let conn_url = db.to_string_lossy().to_string();

    // Run migrations on a direct connection first
    {
        let mut conn = SqliteConnection::establish(&conn_url)
            .map_err(|e| anyhow::anyhow!("Failed to connect to SQLite: {}", e))?;
        conn.run_pending_migrations(MIGRATIONS)
            .map_err(|e| anyhow::anyhow!("Failed to run migrations: {}", e))?;
    }

    // Build connection pool
    let manager = ConnectionManager::<SqliteConnection>::new(&conn_url);
    let pool = Pool::builder()
        .max_size(10)
        .min_idle(Some(2))
        .connection_timeout(std::time::Duration::from_secs(30))
        .connection_customizer(Box::new(SqlitePragmaCustomizer))
        .build(manager)?;

    // Backfill sync_ids
    {
        let mut conn = pool.get().map_err(|e| {
            eprintln!("[db] Connection pool exhausted during setup: {}", e);
            anyhow::anyhow!("Database connection unavailable: {}", e)
        })?;
        backfill_sync_ids(&mut conn)?;
    }

    DB_POOL
        .set(pool)
        .map_err(|_| anyhow::anyhow!("DB_POOL already initialized"))?;

    Ok(())
}

/// Backfill sync_id with UUID v4 for any books that are missing one.
fn backfill_sync_ids(conn: &mut SqliteConnection) -> anyhow::Result<()> {
    #[derive(diesel::QueryableByName)]
    struct BookIdRow {
        #[diesel(sql_type = diesel::sql_types::Integer)]
        id: i32,
    }

    let rows: Vec<BookIdRow> =
        diesel::sql_query("SELECT id FROM books WHERE sync_id IS NULL").load(conn)?;

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

/// Create an in-memory test database with all migrations applied.
#[cfg(test)]
pub fn setup_test_database() -> DbPool {
    let manager = ConnectionManager::<SqliteConnection>::new(":memory:");
    let pool = Pool::builder()
        .max_size(1)
        .build(manager)
        .expect("Failed to create test pool");

    {
        let mut conn = pool.get().expect("Failed to get test connection");
        conn.run_pending_migrations(MIGRATIONS)
            .expect("Failed to run migrations");
    }

    pool
}
