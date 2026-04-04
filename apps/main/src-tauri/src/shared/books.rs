use serde_json::json;
use tauri_plugin_store::StoreExt;

use crate::shared::types::BookData;

pub trait Extractable {
    fn extract(&self) -> Result<BookData, Box<dyn std::error::Error>>;
}

pub fn store_book_data(
    app: tauri::AppHandle,
    extractable: &impl Extractable,
) -> Result<(), String> {
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    let book_data = extractable.extract().map_err(|e| e.to_string())?;

    match store.get("books") {
        Some(value) => {
            let mut current_books: Vec<BookData> =
                serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
            current_books.push(book_data.clone());
            let books_value = serde_json::to_value(current_books).map_err(|e| e.to_string())?;
            store.set("books", json!(books_value));
            store.save().map_err(|e| e.to_string())?;
        }
        None => {
            // No existing books, create new array
            let current_books = vec![book_data.clone()];
            let books_value = serde_json::to_value(current_books).map_err(|e| e.to_string())?;
            store.set("books", json!(books_value));
            store.save().map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
