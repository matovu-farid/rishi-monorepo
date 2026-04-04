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
