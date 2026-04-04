use std::path::PathBuf;

use crate::commands::embed;
use crate::db::DB_POOL;
use crate::embed::{EmbedParam, EmbedResult, Metadata};
use crate::models::{Books, ChunkData};
use crate::schema::{books, chunk_data};
use crate::vectordb::{self, Vector};
use diesel::prelude::*;
use serde::{Deserialize, Serialize};

// Insertable structs for Diesel - must match schema field names (camelCase)
#[derive(Insertable, Clone, Deserialize)]
#[diesel(table_name = chunk_data)]
#[serde(rename_all = "camelCase")]
pub struct ChunkDataInsertable {
    pub id: Option<i64>,
    #[diesel(column_name = pageNumber)]
    pub page_number: i32,
    #[diesel(column_name = bookId)]
    pub book_id: i32,
    pub data: String,
}

#[derive(Insertable, Deserialize)]
#[diesel(table_name = books)]
#[serde(rename_all = "camelCase")]
pub struct BookInsertable {
    pub id: Option<i32>,
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

// Serializable structs for Tauri commands
#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct PageData {
    pub id: i64,
    pub page_number: i32,
    pub book_id: i32,
    pub data: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Book {
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

impl From<Books> for Book {
    fn from(book: Books) -> Self {
        Self {
            id: book.id,
            kind: book.kind,
            cover: book.cover,
            title: book.title,
            author: book.author,
            publisher: book.publisher,
            filepath: book.filepath,
            location: book.location,
            cover_kind: book.cover_kind,
            version: book.version,
        }
    }
}

impl From<ChunkData> for PageData {
    fn from(chunk: ChunkData) -> Self {
        Self {
            id: chunk.id,
            page_number: chunk.page_number,
            book_id: chunk.book_id,
            data: chunk.data,
        }
    }
}

// Internal helper functions
fn has_saved_data(page_number: i32, book_id: i32) -> Result<bool, String> {
    use crate::schema::chunk_data::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let result = chunk_data
        .filter(pageNumber.eq(&page_number))
        .filter(bookId.eq(&book_id))
        .select(id)
        .first::<i64>(&mut conn)
        .optional()
        .map_err(|e| format!("Database query error: {}", e))?;

    Ok(result.is_some())
}

// Public functions that will be exposed as Tauri commands
#[tauri::command]
pub fn save_page_data_many(page_data: Vec<ChunkDataInsertable>) -> Result<(), String> {
    if page_data.is_empty() {
        return Ok(());
    }

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    // For SQLite, insert items one by one with on_conflict handling
    // SQLite doesn't support batch inserts with on_conflict in the same way
    use crate::schema::chunk_data::dsl::*;
    for item in &page_data {
        diesel::insert_into(chunk_data)
            .values(item)
            .on_conflict(id)
            .do_update()
            .set(data.eq(diesel::dsl::sql::<diesel::sql_types::Text>("excluded.data")))
            .execute(&mut conn)
            .map_err(|e| format!("Failed to insert page data: {}", e))?;
    }

    Ok(())
}

#[tauri::command]
pub fn get_all_page_data_by_book_id(book_id: i32) -> Result<Vec<PageData>, String> {
    use crate::schema::chunk_data::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let results = chunk_data
        .filter(bookId.eq(&book_id))
        .order_by(pageNumber.asc())
        .select(ChunkData::as_select())
        .load::<ChunkData>(&mut conn)
        .map_err(|e| format!("Failed to query page data: {}", e))?;

    Ok(results.into_iter().map(PageData::from).collect())
}

#[tauri::command]
pub fn save_book(book: BookInsertable) -> Result<Book, String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    // Try to insert, but ignore conflicts on id
    let result = diesel::insert_into(books)
        .values(&book)
        .on_conflict(id)
        .do_nothing()
        .execute(&mut conn);

    match result {
        Ok(_) => {
            // If insert succeeded, get the inserted book
            books
                .filter(filepath.eq(&book.filepath))
                .select(Books::as_select())
                .first::<Books>(&mut conn)
                .map(Book::from)
                .map_err(|e| format!("Failed to get book: {}", e))
        }
        Err(e) => {
            // If conflict occurred, try to get existing book by filepath
            books
                .filter(filepath.eq(&book.filepath))
                .select(Books::as_select())
                .first::<Books>(&mut conn)
                .map(Book::from)
                .map_err(|_| format!("Failed to save or get book: {}", e))
        }
    }
}

#[tauri::command]
pub fn get_book(book_id: i32) -> Result<Option<Book>, String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let result = books
        .filter(id.eq(&book_id))
        .select(Books::as_select())
        .first::<Books>(&mut conn)
        .optional()
        .map_err(|e| format!("Failed to query book: {}", e))?;

    Ok(result.map(Book::from))
}

#[tauri::command]
pub fn get_books() -> Result<Vec<Book>, String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let results = books
        .select(Books::as_select())
        .load::<Books>(&mut conn)
        .map_err(|e| format!("Failed to query books: {}", e))?;

    Ok(results.into_iter().map(Book::from).collect())
}

#[tauri::command]
pub fn delete_book(book_id: i32) -> Result<(), String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    diesel::delete(books.filter(id.eq(&book_id)))
        .execute(&mut conn)
        .map_err(|e| format!("Failed to delete book: {}", e))?;

    Ok(())
}

#[tauri::command]
pub fn update_book_cover(book_id: i32, new_cover: Vec<u8>) -> Result<(), String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    diesel::update(books.filter(id.eq(&book_id)))
        .set(cover.eq(&new_cover))
        .execute(&mut conn)
        .map_err(|e| format!("Failed to update book cover: {}", e))?;

    Ok(())
}

pub async fn process_job(
    page_number: i32,
    book_id: i32,
    page_data: Vec<ChunkDataInsertable>,
    app_data_dir: &PathBuf,
) -> Result<(), String> {
    // Check if data already exists
    if has_saved_data(page_number, book_id)? {
        return Ok(());
    }

    if page_data.is_empty() {
        return Ok(());
    }

    // Prepare embed parameters
    let embed_params: Vec<EmbedParam> = page_data
        .iter()
        .map(|item| {
            let metadata = Metadata {
                id: item.id.unwrap_or(0) as u64,
                page_number: page_number as usize,
                book_id: book_id as u32,
            };
            EmbedParam {
                text: item.data.clone(),
                metadata,
            }
        })
        .collect();

    // Save page data first (ensures data is in DB even if embedding fails)
    save_page_data_many(page_data.clone())?;

    // Embed the text using the command
    let embed_results: Vec<EmbedResult> = embed(embed_params).await?;

    if embed_results.is_empty() {
        return Err("No embedding results returned".to_string());
    }

    // Prepare vectors
    let vectors: Vec<Vector> = embed_results
        .iter()
        .map(|result| Vector {
            id: result.metadata.id,
            vector: result.embedding.clone(),
        })
        .collect();

    let dim = embed_results[0].embedding.len();

    // Save vectors using the existing command

    // save_vectors(app, &format!("{}-vectordb", book_id), dim, vectors)?;
    let name = format!("{}-vectordb", book_id);
    vectordb::save_vectors(vectors, app_data_dir.clone(), dim, &name).map_err(|e| e.to_string())?;

    Ok(())
}

#[tauri::command]
pub fn has_saved_epub_data(book_id: i32) -> Result<bool, String> {
    use crate::schema::chunk_data::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let result = chunk_data
        .filter(bookId.eq(&book_id))
        .select(id)
        .first::<i64>(&mut conn)
        .optional()
        .map_err(|e| format!("Database query error: {}", e))?;

    Ok(result.is_some())
}

pub async fn get_context_for_query(
    query_text: String,
    book_id: u32,
    app_data_dir: &PathBuf,
    k: usize,
) -> Result<Vec<String>, String> {
    let embed_params = vec![EmbedParam {
        text: query_text,
        metadata: Metadata {
            id: 0,
            page_number: 0,
            book_id,
        },
    }];
    let embed_results = embed(embed_params).await?;
    let query = embed_results[0].embedding.clone();
    let dim = embed_results[0].embedding.len();
    let name = format!("{}-vectordb", book_id);
    let search_embeddings = vectordb::search_vectors(app_data_dir.clone(), dim, &name, query, k)
        .map_err(|e| e.to_string())?;
    // use the result to query the db for the actual text using the ids
    let text = search_embeddings
        .iter()
        .map(|result| get_text_from_vector_id(result.id as i64))
        .collect::<Result<Vec<String>, String>>()?;
    Ok(text)
}

#[tauri::command]
pub fn update_book_location(book_id: i32, new_location: String) -> Result<(), String> {
    use crate::schema::books::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    diesel::update(books.filter(id.eq(&book_id)))
        .set(location.eq(&new_location))
        .execute(&mut conn)
        .map_err(|e| format!("Failed to update book location: {}", e))?;

    Ok(())
}

#[tauri::command]
pub fn get_text_from_vector_id(vector_id: i64) -> Result<String, String> {
    use crate::schema::chunk_data::dsl::*;

    let pool = DB_POOL.get().ok_or("Database pool not initialized")?;
    let mut conn = pool
        .get()
        .map_err(|e| format!("Failed to get connection: {}", e))?;

    let result = chunk_data
        .filter(id.eq(&vector_id))
        .select(data)
        .first::<String>(&mut conn)
        .optional()
        .map_err(|e| format!("Database query error: {}", e))?;

    Ok(result.unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use crate::test_fixtures;
    use crate::test_helpers::init_test_database_setup;
    use expectest::prelude::*;
    use pretty_assertions::assert_eq as pretty_assert_eq;

    use super::{
        delete_book, get_all_page_data_by_book_id, get_book, save_book, save_page_data_many,
        update_book_cover, BookInsertable, ChunkDataInsertable,
    };

    #[test]
    fn test_save_page_data_many() -> Result<(), String> {
        // Initialize test database
        let _setup = init_test_database_setup()?;
        let book_id = 1;

        let page_data = vec![
            ChunkDataInsertable {
                id: Some(1),
                page_number: 1,
                book_id,
                data: "test".to_string(),
            },
            ChunkDataInsertable {
                id: Some(2),
                page_number: 2,
                book_id,
                data: "test2".to_string(),
            },
        ];
        save_page_data_many(page_data).unwrap();

        // check that they exist in the database using expect-style assertions
        let result = get_all_page_data_by_book_id(book_id).unwrap();
        expect!(result.len()).to(be_equal_to(2));
        expect!(result[0].page_number).to(be_equal_to(1));
        expect!(result[0].data.as_str()).to(be_equal_to("test"));
        expect!(result[1].page_number).to(be_equal_to(2));
        expect!(result[1].data.as_str()).to(be_equal_to("test2"));
        Ok(())
    }
    // embed data , save vectors and query the text from the vector id and fetch the text from the vector id to confirm
    #[tokio::test]
    async fn test_embed_data_and_save_vectors() -> Result<(), String> {
        // Initialize test database
        let setup = init_test_database_setup()?;
        let book_id = 1;
        let test_chunks = test_fixtures::get_test_chunks();
        let page_data: Vec<ChunkDataInsertable> = test_chunks
            .iter()
            .enumerate()
            .map(|(idx, chunk)| ChunkDataInsertable {
                id: Some(chunk.id),
                page_number: (idx + 1) as i32,
                book_id,
                data: chunk.text.to_string(),
            })
            .collect();

        // Use temp directory for vectordb files
        let app_data_dir = &setup.app_data_dir;

        use super::process_job;
        process_job(1, 1, page_data, app_data_dir).await?;

        // Test each chunk's related query to verify it returns the correct paragraph
        // Note: temp_dir stays alive for the entire test and is automatically cleaned up when it goes out of scope
        use super::get_context_for_query;
        for chunk in &test_chunks {
            let results =
                get_context_for_query(chunk.query.to_string(), book_id as u32, app_data_dir, 3)
                    .await?;

            // The query should return the related paragraph as the first result
            expect!(results.is_empty()).to(be_equal_to(false));

            // Use pretty_assertions for better diff display on failure
            pretty_assert_eq!(
                results[0],
                chunk.text,
                "Query '{}' should return the related paragraph, but got: '{}'",
                chunk.query,
                results[0]
            );
        }

        Ok(())
    }

    #[test]
    fn test_save_and_retrieve_book() -> Result<(), String> {
        // Initialize test database
        let _setup = init_test_database_setup()?;

        // Create a test book with sensible data
        let test_book = BookInsertable {
            id: None, // Let the database assign the ID
            kind: "epub".to_string(),
            cover: vec![0x89, 0x50, 0x4E, 0x47], // PNG magic bytes as test cover
            title: "The Test Book".to_string(),
            author: "Test Author".to_string(),
            publisher: "Test Publisher".to_string(),
            filepath: "/path/to/test/book.epub".to_string(),
            location: "epubcfi(/6/4[chap01ref]!/4/2/2)".to_string(),
            cover_kind: "image/png".to_string(),
            version: 1,
        };

        // Save the book
        let saved_book = save_book(test_book)?;

        // Verify the book was saved with an ID
        expect!(saved_book.id).to(be_greater_than(0));
        expect!(saved_book.title.as_str()).to(be_equal_to("The Test Book"));
        expect!(saved_book.author.as_str()).to(be_equal_to("Test Author"));
        expect!(saved_book.publisher.as_str()).to(be_equal_to("Test Publisher"));
        expect!(saved_book.filepath.as_str()).to(be_equal_to("/path/to/test/book.epub"));
        expect!(saved_book.kind.as_str()).to(be_equal_to("epub"));
        expect!(saved_book.cover_kind.as_str()).to(be_equal_to("image/png"));
        expect!(saved_book.version).to(be_equal_to(1));
        expect!(saved_book.cover.len()).to(be_equal_to(4));

        // Retrieve the book by ID
        let retrieved_book = get_book(saved_book.id)?;

        // Verify the book exists and matches what was saved
        expect!(retrieved_book.is_some()).to(be_equal_to(true));
        let book = retrieved_book.unwrap();
        expect!(book.id).to(be_equal_to(saved_book.id));
        expect!(book.title.as_str()).to(be_equal_to("The Test Book"));
        expect!(book.author.as_str()).to(be_equal_to("Test Author"));
        expect!(book.publisher.as_str()).to(be_equal_to("Test Publisher"));
        expect!(book.filepath.as_str()).to(be_equal_to("/path/to/test/book.epub"));
        expect!(book.location.as_str()).to(be_equal_to("epubcfi(/6/4[chap01ref]!/4/2/2)"));
        expect!(book.kind.as_str()).to(be_equal_to("epub"));
        expect!(book.cover_kind.as_str()).to(be_equal_to("image/png"));
        expect!(book.version).to(be_equal_to(1));
        expect!(book.cover).to(be_equal_to(saved_book.cover));

        Ok(())
    }

    #[test]
    fn test_save_delete_and_verify_book_removed() -> Result<(), String> {
        // Initialize test database
        let _setup = init_test_database_setup()?;

        // Create a test book with sensible data
        let test_book = BookInsertable {
            id: None, // Let the database assign the ID
            kind: "epub".to_string(),
            cover: vec![0xFF, 0xD8, 0xFF, 0xE0], // JPEG magic bytes as test cover
            title: "Book To Delete".to_string(),
            author: "Delete Author".to_string(),
            publisher: "Delete Publisher".to_string(),
            filepath: "/path/to/delete/book.epub".to_string(),
            location: "epubcfi(/6/4[chap02ref]!/4/2/2)".to_string(),
            cover_kind: "image/jpeg".to_string(),
            version: 2,
        };

        // Save the book
        let saved_book = save_book(test_book)?;

        // Verify the book was saved with an ID
        expect!(saved_book.id).to(be_greater_than(0));
        let book_id = saved_book.id;

        // Verify the book exists before deletion
        let retrieved_book_before = get_book(book_id)?;
        expect!(retrieved_book_before.is_some()).to(be_equal_to(true));
        let book_before = retrieved_book_before.unwrap();
        expect!(book_before.id).to(be_equal_to(book_id));
        expect!(book_before.title.as_str()).to(be_equal_to("Book To Delete"));

        // Delete the book
        delete_book(book_id)?;

        // Verify the book no longer exists
        let retrieved_book_after = get_book(book_id)?;
        expect!(retrieved_book_after.is_none()).to(be_equal_to(true));

        Ok(())
    }

    #[test]
    fn test_update_book_cover() -> Result<(), String> {
        // Initialize test database
        let _setup = init_test_database_setup()?;

        // Create a test book with an empty cover
        let test_book = BookInsertable {
            id: None, // Let the database assign the ID
            kind: "epub".to_string(),
            cover: vec![], // Empty cover
            title: "Book With Cover Update".to_string(),
            author: "Cover Author".to_string(),
            publisher: "Cover Publisher".to_string(),
            filepath: "/path/to/cover/book.epub".to_string(),
            location: "epubcfi(/6/4[chap03ref]!/4/2/2)".to_string(),
            cover_kind: "image/png".to_string(),
            version: 1,
        };

        // Save the book
        let saved_book = save_book(test_book)?;
        let book_id = saved_book.id;

        // Verify the book was saved with an empty cover
        expect!(saved_book.cover.is_empty()).to(be_equal_to(true));

        // Retrieve the book to confirm empty cover
        let retrieved_book_before = get_book(book_id)?;
        expect!(retrieved_book_before.is_some()).to(be_equal_to(true));
        let book_before = retrieved_book_before.unwrap();
        expect!(book_before.cover.is_empty()).to(be_equal_to(true));

        // Update the book cover with test image data (PNG magic bytes + some additional data)
        let new_cover_data = vec![
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic bytes
            0x00, 0x00, 0x00, 0x0D, // IHDR chunk length
            0x49, 0x48, 0x44, 0x52, // IHDR
        ];
        update_book_cover(book_id, new_cover_data.clone())?;

        // Retrieve the book and verify the cover matches what we set
        let retrieved_book_after = get_book(book_id)?;
        expect!(retrieved_book_after.is_some()).to(be_equal_to(true));
        let book_after = retrieved_book_after.unwrap();
        expect!(book_after.cover.len()).to(be_equal_to(16));
        expect!(book_after.cover).to(be_equal_to(new_cover_data));

        Ok(())
    }
}
