use diesel::prelude::*;
use diesel::sqlite::SqliteConnection;
use diesel_migrations::MigrationHarness;
use rishi_dioxus::db::MIGRATIONS;
use rishi_dioxus::models::*;
use rishi_dioxus::schema::*;

fn setup_conn() -> SqliteConnection {
    let mut conn = SqliteConnection::establish(":memory:")
        .expect("Failed to create in-memory SQLite connection");
    conn.run_pending_migrations(MIGRATIONS)
        .expect("Failed to run migrations");
    conn
}

#[test]
fn test_insert_and_query_book() {
    let mut conn = setup_conn();

    diesel::sql_query(
        "INSERT INTO books (kind, cover, title, author, publisher, filepath, location, cover_kind, version, format)
         VALUES ('epub', X'89504E47', 'Test Book', 'Jane Doe', 'Acme Press', '/tmp/test.epub', 'epubcfi(/6/2)', 'png', 1, 'epub')"
    )
    .execute(&mut conn)
    .expect("Failed to insert book");

    let results = books::table
        .select(Book::as_select())
        .load::<Book>(&mut conn)
        .expect("Failed to query books");

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].title, "Test Book");
    assert_eq!(results[0].kind, "epub");
    assert_eq!(results[0].author, "Jane Doe");
}

#[test]
fn test_insert_and_query_highlight() {
    let mut conn = setup_conn();

    diesel::sql_query(
        "INSERT INTO highlights (id, book_id, cfi_range, text, color)
         VALUES ('h1', 'b1', 'epubcfi(/6/4)', 'highlighted text', 'blue')"
    )
    .execute(&mut conn)
    .expect("Failed to insert highlight");

    let results = highlights::table
        .select(Highlight::as_select())
        .load::<Highlight>(&mut conn)
        .expect("Failed to query highlights");

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].text, "highlighted text");
    assert_eq!(results[0].color, "blue");
}

#[test]
fn test_insert_and_query_conversation_with_messages() {
    let mut conn = setup_conn();

    diesel::sql_query(
        "INSERT INTO conversations (id, book_id, title)
         VALUES ('c1', 'b1', 'My Chat')"
    )
    .execute(&mut conn)
    .expect("Failed to insert conversation");

    diesel::sql_query(
        "INSERT INTO messages (id, conversation_id, role, content)
         VALUES ('m1', 'c1', 'user', 'What is this book about?')"
    )
    .execute(&mut conn)
    .expect("Failed to insert message");

    let msgs = messages::table
        .filter(messages::conversation_id.eq("c1"))
        .select(Message::as_select())
        .load::<Message>(&mut conn)
        .expect("Failed to query messages");

    assert_eq!(msgs.len(), 1);
    assert_eq!(msgs[0].role, "user");
    assert_eq!(msgs[0].conversation_id, "c1");
}

#[test]
fn test_insert_and_query_bookmark() {
    let mut conn = setup_conn();

    diesel::sql_query(
        "INSERT INTO bookmarks (id, book_id, location, label)
         VALUES ('bm1', 'b1', 'epubcfi(/6/8)', 'Chapter 3')"
    )
    .execute(&mut conn)
    .expect("Failed to insert bookmark");

    let results = bookmarks::table
        .select(Bookmark::as_select())
        .load::<Bookmark>(&mut conn)
        .expect("Failed to query bookmarks");

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].label, Some("Chapter 3".to_string()));
}

#[test]
fn test_sync_meta_seeded() {
    let mut conn = setup_conn();

    let results = sync_meta::table
        .filter(sync_meta::id.eq("default"))
        .select(SyncMeta::as_select())
        .load::<SyncMeta>(&mut conn)
        .expect("Failed to query sync_meta");

    assert_eq!(results.len(), 1);
    assert_eq!(results[0].last_sync_version, 0);
}

#[test]
fn test_fts_search() {
    let mut conn = setup_conn();

    // Insert two chunks — one about a fox, one about a cat
    diesel::sql_query(
        "INSERT INTO chunk_data (id, pageNumber, bookId, data)
         VALUES (1, 1, 1, 'The quick brown fox jumps over the lazy dog')"
    )
    .execute(&mut conn)
    .expect("Failed to insert chunk 1");

    diesel::sql_query(
        "INSERT INTO chunk_data (id, pageNumber, bookId, data)
         VALUES (2, 2, 1, 'The cat sat on the mat')"
    )
    .execute(&mut conn)
    .expect("Failed to insert chunk 2");

    // FTS MATCH search for 'fox'
    #[derive(diesel::QueryableByName, Debug)]
    struct FtsResult {
        #[diesel(sql_type = diesel::sql_types::BigInt)]
        id: i64,
        #[diesel(sql_type = diesel::sql_types::Text)]
        data: String,
    }

    let results: Vec<FtsResult> = diesel::sql_query(
        "SELECT cd.id, cd.data FROM chunk_data cd
         INNER JOIN chunk_data_fts fts ON cd.id = fts.rowid
         WHERE chunk_data_fts MATCH 'fox'"
    )
    .load(&mut conn)
    .expect("Failed to run FTS search");

    assert_eq!(results.len(), 1);
    assert!(results[0].data.contains("fox"));
    assert_eq!(results[0].id, 1);
}
