use diesel::prelude::*;

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::books)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct Books {
    pub id: i32,
    pub kind: String,
    pub cover: Vec<u8>,
    pub title: String,
    pub author: String,
    pub publisher: String,
    pub filepath: String,
    pub location: String,
    pub cover_kind: String,
    pub version: i32,
    pub sync_id: Option<String>,
    pub file_hash: Option<String>,
    pub file_r2_key: Option<String>,
    pub cover_r2_key: Option<String>,
    pub format: String,
    pub current_cfi: Option<String>,
    pub current_page: Option<i32>,
    pub user_id: Option<String>,
    pub sync_version: i32,
    pub is_dirty: i32,
    pub is_deleted: i32,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::chunk_data)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct ChunkData {
    pub id: i64,
    #[diesel(column_name = pageNumber)]
    pub page_number: i32,
    #[diesel(column_name = bookId)]
    pub book_id: i32,
    pub data: String,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::highlights)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct Highlight {
    pub id: String,
    pub book_id: String,
    pub user_id: Option<String>,
    pub cfi_range: String,
    pub text: String,
    pub color: String,
    pub note: Option<String>,
    pub chapter: Option<String>,
    pub created_at: i32,
    pub updated_at: i32,
    pub sync_version: i32,
    pub is_dirty: i32,
    pub is_deleted: i32,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::conversations)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct Conversation {
    pub id: String,
    pub book_id: String,
    pub user_id: Option<String>,
    pub title: String,
    pub created_at: i32,
    pub updated_at: i32,
    pub sync_version: i32,
    pub is_dirty: i32,
    pub is_deleted: i32,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::messages)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct Message {
    pub id: String,
    pub conversation_id: String,
    pub role: String,
    pub content: String,
    pub source_chunks: Option<String>,
    pub created_at: i32,
    pub updated_at: i32,
    pub sync_version: i32,
    pub is_dirty: i32,
    pub is_deleted: i32,
}

#[derive(Queryable, Selectable)]
#[diesel(table_name = crate::schema::sync_meta)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct SyncMeta {
    pub id: String,
    pub last_sync_version: i32,
    pub last_sync_at: Option<i32>,
}
