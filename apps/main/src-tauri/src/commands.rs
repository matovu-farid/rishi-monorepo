use std::fs;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use zip::ZipArchive;
// At the top of commands.rs
use crate::embed::EmbedResult;
use crate::embed::{embed_text, EmbedParam};
use crate::epub::Epub;
use crate::pdf::Pdf;
use crate::shared::books::store_book_data;
use crate::shared::books::Extractable;
use crate::shared::types::BookData;
use crate::sql;
use crate::sql::ChunkDataInsertable;
use crate::user::User;
use crate::vectordb::{self, SearchResult, Vector};
use serde_json::json;
use tauri::Manager;
use tauri_plugin_store::StoreExt;

#[tauri::command]
pub fn get_book_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Epub::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn process_job(
    app: tauri::AppHandle,
    page_number: i32,
    book_id: i32,
    page_data: Vec<ChunkDataInsertable>,
) -> Result<(), String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data directory: {:?}", e))?;
    sql::process_job(page_number, book_id, page_data, &app_data_dir).await
}
#[tauri::command]
pub async fn poll_for_user(state: &str, timeout_sec: u64) -> Result<User, String> {
    let worker_url = "https://rishi-worker.faridmato90.workers.dev";
    let path = format!("/api/user/{}", state);
    let url = format!("{}{}", worker_url, path);

    let client = reqwest::Client::new();
    let mut elapsed = 0;
    let interval = 2; // seconds
    while elapsed < timeout_sec {
        let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
        if response.status().is_success() {
            let user: User = response.json::<User>().await.map_err(|e| e.to_string())?;
            return Ok(user);
        }
        tokio::time::sleep(std::time::Duration::from_secs(interval)).await;
        elapsed += interval;
    }
    Err("Timeout reached while polling for user ID".to_string())
}

#[tauri::command]
pub async fn get_context_for_query(
    app: tauri::AppHandle,
    query_text: String,
    book_id: u32,
    k: usize,
) -> Result<Vec<String>, String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data directory: {:?}", e))?;
    sql::get_context_for_query(query_text, book_id, &app_data_dir, k).await
}

#[tauri::command]
pub fn save_vectors(
    app: tauri::AppHandle,
    name: &str,
    dim: usize,
    vectors: Vec<Vector>,
) -> Result<(), String> {
    if vectors.is_empty() {
        return Err("Vectors cannot be empty".to_string());
    }
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data directory: {:?}", e))?;

    vectordb::save_vectors(vectors, app_data_dir, dim, name).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_state() -> String {
    use uuid::Uuid;
    // create a random state
    let state = Uuid::new_v4().to_string();
    state
}
#[tauri::command]
pub async fn signout(app: tauri::AppHandle) -> Result<(), String> {
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    let deleted = store.delete("user");
    if !deleted {
        return Err("User not found".to_string());
    }
    store.save().map_err(|e| e.to_string())?;
    Ok(())
}
#[tauri::command]
pub fn get_user_from_store(app: tauri::AppHandle) -> Result<User, String> {
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    let user_value = store.get("user").ok_or("User not found")?;
    let user: User = serde_json::from_value(user_value).map_err(|e| e.to_string())?;
    Ok(user)
}

#[tauri::command]
pub async fn get_user(app: tauri::AppHandle, user_id: &str) -> Result<User, String> {
    // /api/clerk/user/:userId from the worker
    let worker_url = "https://rishi-worker.faridmato90.workers.dev";
    let path = format!("/api/clerk/user/{}", user_id);
    let url = format!("{}{}", worker_url, path);
    let response = reqwest::get(url).await.map_err(|e| e.to_string())?;
    println!("response: {:?}", response);
    let user = response.json::<User>().await.map_err(|e| e.to_string())?;
    // save user to the database

    let store = app.store("store.json").map_err(|e| e.to_string())?;
    store.set("user", json!(user));
    store.save().map_err(|e| e.to_string())?;
    Ok(user)
}
#[tauri::command]
pub fn search_vectors(
    app: tauri::AppHandle,
    name: &str,
    query: Vec<f32>,
    dim: usize,
    k: usize,
) -> Result<Vec<SearchResult>, String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Failed to get app data directory: {:?}", e))?;

    vectordb::search_vectors(app_data_dir, dim, name, query, k).map_err(|e| e.to_string())
}
#[tauri::command]
pub fn get_pdf_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Pdf::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn embed(embedparams: Vec<EmbedParam>) -> Result<Vec<EmbedResult>, String> {
    let res = embed_text(embedparams).await.map_err(|e| e.to_string())?;
    Ok(res)
}

#[tauri::command]
pub fn is_dev() -> bool {
    tauri::is_dev()
}

#[tauri::command]
pub fn unzip(file_path: &str, out_dir: &str) -> Result<PathBuf, String> {
    println!(
        "unzip called with file_path: {:?}, out_dir: {:?}",
        file_path, out_dir
    );
    let file = File::open(file_path).map_err(|e| e.to_string())?;
    let mut archive = ZipArchive::new(file).map_err(|e| e.to_string())?;

    let output_dir = Path::new(out_dir);
    fs::create_dir_all(&output_dir).map_err(|e| e.to_string())?;

    // Extract all files (like AdmZip's `extractAllTo`)
    for i in 0..archive.len() {
        let mut file = archive.by_index(i).map_err(|e| e.to_string())?;
        let outpath = output_dir.join(file.name());

        if file.name().ends_with('/') {
            fs::create_dir_all(&outpath).map_err(|e| e.to_string())?;
        } else {
            if let Some(parent) = outpath.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let mut outfile = File::create(&outpath).map_err(|e| e.to_string())?;
            io::copy(&mut file, &mut outfile).map_err(|e| e.to_string())?;
        }
    }

    // Copy the original zip file into the extracted folder (AdmZip analog)
    let zip_filename = Path::new(file_path)
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let new_zip_file_path = output_dir.join(zip_filename);
    fs::copy(file_path, &new_zip_file_path).map_err(|e| e.to_string())?;

    // println!("File was copied to {:?}", new_zip_file_path);

    Ok(output_dir.to_path_buf())
}
