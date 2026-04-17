use std::fs;
use std::fs::File;
use std::io;
use std::path::{Path, PathBuf};
use zip::ZipArchive;
// At the top of commands.rs
use crate::embed::EmbedResult;
use crate::embed::{embed_text, EmbedParam};
use crate::djvu::Djvu;
use crate::epub::Epub;
use crate::mobi::Mobi;
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

const KEYRING_SERVICE: &str = "com.fidexa.rishi";

/// Store a value in the OS keychain.
fn keyring_set(key: &str, value: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, key).map_err(|e| e.to_string())?;
    entry.set_password(value).map_err(|e| e.to_string())
}

/// Read a value from the OS keychain. Returns None if not found.
fn keyring_get(key: &str) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(val) => Ok(Some(val)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Delete a value from the OS keychain. Ignores "not found" errors.
fn keyring_delete(key: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// Migrate auth secrets from store.json to OS keychain (one-time, on app startup).
pub fn migrate_auth_to_keychain(app: &tauri::AppHandle) -> Result<(), String> {
    let store = app.store("store.json").map_err(|e| e.to_string())?;

    // Only migrate if token exists in store but NOT in keychain
    if let Some(token_value) = store.get("auth_token") {
        if let Some(token) = token_value.as_str() {
            if keyring_get("auth_token")?.is_none() {
                keyring_set("auth_token", token)?;

                if let Some(exp) = store.get("auth_expires_at") {
                    keyring_set("auth_expires_at", &exp.to_string())?;
                }

                // Clean up secrets from the plain-text store
                store.delete("auth_token");
                store.delete("auth_expires_at");
                store.save().map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(())
}

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

/// Best-effort debug log to the worker's `/api/auth/debug` endpoint.
/// Fires and forgets — errors are silently ignored so they never block auth.
pub async fn log_auth_debug_fn(state: &str, source: &str, step: &str, data: Option<serde_json::Value>, error: Option<&str>) {
    let worker_url = crate::WORKER_URL;
    let url = format!("{}/api/auth/debug", worker_url);
    let client = reqwest::Client::new();
    let mut payload = json!({
        "state": state,
        "source": source,
        "step": step,
    });
    if let Some(d) = data {
        payload["data"] = d;
    }
    if let Some(e) = error {
        payload["error"] = json!(e);
    }
    let _ = client.post(&url).json(&payload).send().await;
}

/// Tauri command: log auth debug events from the TS frontend.
#[tauri::command]
pub async fn log_auth_debug_cmd(state: String, step: String, data: Option<serde_json::Value>, error: Option<String>) -> Result<(), String> {
    log_auth_debug_fn(&state, "tauri-ts", &step, data, error.as_deref()).await;
    Ok(())
}

/// Tauri command: fetch auth debug log from the worker.
#[tauri::command]
pub async fn get_auth_debug(state: String) -> Result<serde_json::Value, String> {
    let worker_url = crate::WORKER_URL;
    let url = format!("{}/api/auth/debug/{}", worker_url, &state);
    let client = reqwest::Client::new();
    let response = client.get(&url).send().await.map_err(|e| e.to_string())?;
    let value: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
    Ok(value)
}

/// Complete auth flow using the state parameter from the deep link.
/// The worker looks up the userId from Redis (stored by the web app),
/// verifies with Clerk, and issues a JWT — no tokens pass through the deep link.
/// Sends the code_verifier for PKCE-like proof-of-possession.
#[tauri::command]
pub async fn complete_auth(app: tauri::AppHandle, state: &str) -> Result<User, String> {
    log_auth_debug_fn(state, "tauri-rust", "complete_auth_called", None, None).await;

    // Read code_verifier from the persistent store
    let store = app.store("store.json").map_err(|e| {
        let msg = format!("Failed to open store: {}", e);
        // fire-and-forget — block on the log only in the error path
        let s = state.to_string();
        let m = msg.clone();
        tokio::spawn(async move { log_auth_debug_fn(&s, "tauri-rust", "complete_auth_store_error", None, Some(&m)).await; });
        msg
    })?;

    let code_verifier = store
        .get("auth_code_verifier")
        .ok_or_else(|| "Missing code_verifier — please login again".to_string());

    let code_verifier = match code_verifier {
        Ok(v) => v,
        Err(e) => {
            // Log what IS in the store for debugging
            let has_state = store.get("auth_state").is_some();
            let has_created = store.get("auth_state_created_at").is_some();
            log_auth_debug_fn(state, "tauri-rust", "complete_auth_no_verifier",
                Some(json!({ "hasAuthState": has_state, "hasCreatedAt": has_created })),
                Some(&e)).await;
            return Err(e);
        }
    };

    let code_verifier = code_verifier
        .as_str()
        .ok_or("Invalid code_verifier format")?
        .to_string();

    log_auth_debug_fn(state, "tauri-rust", "complete_auth_verifier_read",
        Some(json!({ "verifierLen": code_verifier.len() })), None).await;

    let worker_url = crate::WORKER_URL;
    let url = format!("{}/api/auth/complete", worker_url);

    let client = reqwest::Client::new();
    log_auth_debug_fn(state, "tauri-rust", "complete_auth_calling_worker",
        Some(json!({ "url": url })), None).await;

    let response = client
        .post(&url)
        .json(&json!({ "state": state, "code_verifier": code_verifier }))
        .send()
        .await
        .map_err(|e| {
            let msg = format!("Network error calling worker: {}", e);
            eprintln!("[complete_auth] {}", msg);
            msg
        });

    let response = match response {
        Ok(r) => r,
        Err(e) => {
            log_auth_debug_fn(state, "tauri-rust", "complete_auth_network_error", None, Some(&e)).await;
            return Err(e);
        }
    };

    let status = response.status();
    log_auth_debug_fn(state, "tauri-rust", "complete_auth_worker_responded",
        Some(json!({ "status": status.as_u16() })), None).await;

    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let err_msg = format!("Auth completion failed ({}): {}", status, body);
        log_auth_debug_fn(state, "tauri-rust", "complete_auth_worker_error",
            Some(json!({ "status": status.as_u16(), "body": body })), Some(&err_msg)).await;
        return Err(err_msg);
    }

    let exchange_response: serde_json::Value =
        response.json().await.map_err(|e| e.to_string())?;

    let token = exchange_response["token"]
        .as_str()
        .ok_or("Missing token in response")?;
    let user: User = serde_json::from_value(exchange_response["user"].clone())
        .map_err(|e| e.to_string())?;

    let expires_at = exchange_response["expiresAt"]
        .as_i64()
        .unwrap_or(0);

    // Store token and expiry in OS keychain (not plain JSON)
    keyring_set("auth_token", token)?;
    keyring_set("auth_expires_at", &expires_at.to_string())?;

    // User profile (non-secret) stays in store.json for easy TS access
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    store.set("user", json!(user));
    store.save().map_err(|e| e.to_string())?;

    log_auth_debug_fn(state, "tauri-rust", "complete_auth_success",
        Some(json!({ "userId": user.id })), None).await;

    Ok(user)
}

/// Response shape from the worker's `/api/auth/status/:state` endpoint.
/// All fields are optional because the worker returns different shapes for
/// not-found (`{ status: "not_found" }`), found (`{ status, retryCount,
/// createdAt }`), and error (`{ error }`) cases.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatusResponse {
    pub status: Option<String>,
    pub retry_count: Option<u32>,
    pub created_at: Option<u64>,
    pub error: Option<String>,
}

/// Check auth flow status from Redis for monitoring and retry decisions.
#[tauri::command]
pub async fn check_auth_status(app: tauri::AppHandle, state: &str) -> Result<AuthStatusResponse, String> {
    // Validate state is a well-formed UUID before interpolating into a URL
    uuid::Uuid::parse_str(state)
        .map_err(|_| "Invalid state parameter — expected UUID format".to_string())?;

    // Read the stored code_verifier and compute code_challenge so the status
    // endpoint can verify we own this auth flow.
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    let code_verifier = store
        .get("auth_code_verifier")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .ok_or_else(|| "No code_verifier in store".to_string())?;

    use sha2::{Sha256, Digest};
    let hash = Sha256::digest(code_verifier.as_bytes());
    let code_challenge = hash.iter().map(|b| format!("{:02x}", b)).collect::<String>();

    let worker_url = crate::WORKER_URL;
    let url = format!("{}/api/auth/status/{}", worker_url, state);
    let client = reqwest::Client::new();
    let response = client
        .post(&url)
        .json(&json!({ "code_challenge": code_challenge }))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let value: AuthStatusResponse = response.json().await.map_err(|e| e.to_string())?;
    Ok(value)
}

pub fn get_auth_token(_app: &tauri::AppHandle) -> Result<String, String> {
    // Check expiry from keychain
    if let Some(exp_str) = keyring_get("auth_expires_at")? {
        let expires_at: u64 = exp_str.parse().map_err(|_| "Invalid auth_expires_at format")?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        if now > expires_at {
            return Err("Token expired — please log in again".to_string());
        }
    }

    keyring_get("auth_token")?.ok_or_else(|| "Not authenticated".to_string())
}

/// Tauri command wrapper so the TS frontend can retrieve the auth token
/// without direct store access. The token never transits to JS unless
/// explicitly requested via this IPC call.
#[tauri::command]
pub fn get_auth_token_cmd(app: tauri::AppHandle) -> Result<String, String> {
    get_auth_token(&app)
}

async fn authenticated_get(app: &tauri::AppHandle, url: &str) -> Result<reqwest::Response, String> {
    let token = get_auth_token(app)?;
    let client = reqwest::Client::new();
    let response = client
        .get(url)
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| e.to_string())?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err("Session expired — please log in again".to_string());
    }
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Request failed ({}): {}", status, body));
    }
    Ok(response)
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

/// The OAuth `state` UUID plus the `code_challenge` derived from the
/// internally-stored code_verifier. Returned by `get_state` so the frontend
/// can construct the sign-in URL without ever seeing the code_verifier.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthStateResponse {
    pub state: String,
    pub code_challenge: String,
}

#[tauri::command]
pub fn get_state(app: tauri::AppHandle) -> Result<OAuthStateResponse, String> {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine;
    use rand::RngCore;
    use uuid::Uuid;

    // Generate a random state UUID
    let state = Uuid::new_v4().to_string();

    // Generate a random code_verifier (32 bytes, base64url-encoded)
    let mut verifier_bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut verifier_bytes);
    let code_verifier = URL_SAFE_NO_PAD.encode(verifier_bytes);

    // Persist both in the Tauri store so they survive restarts
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    store.set("auth_state", json!(state));
    store.set("auth_code_verifier", json!(code_verifier));
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis() as u64;
    store.set("auth_state_created_at", json!(now_ms));
    store.save().map_err(|e| e.to_string())?;

    // Compute code_challenge = hex(SHA-256(code_verifier)) so the verifier
    // never leaves the Rust process.
    use sha2::{Sha256, Digest};
    let hash = Sha256::digest(code_verifier.as_bytes());
    let code_challenge = hash.iter().map(|b| format!("{:02x}", b)).collect::<String>();

    Ok(OAuthStateResponse { state, code_challenge })
}

#[tauri::command]
pub async fn signout(app: tauri::AppHandle) -> Result<(), String> {
    // Best-effort: revoke the token on the server before deleting locally
    if let Some(token) = keyring_get("auth_token")? {
        let worker_url = crate::WORKER_URL;
        let url = format!("{}/api/auth/revoke", worker_url);
        let client = reqwest::Client::new();
        let _ = client
            .post(&url)
            .header("Authorization", format!("Bearer {}", token))
            .send()
            .await;
    }

    // Delete secrets from keychain
    keyring_delete("auth_token")?;
    keyring_delete("auth_expires_at")?;

    // Delete non-secret user profile from store
    let store = app.store("store.json").map_err(|e| e.to_string())?;
    store.delete("user");
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
    let worker_url = crate::WORKER_URL;
    let url = format!("{}/api/clerk/user/{}", worker_url, user_id);
    let response = authenticated_get(&app, &url).await?;
    let user = response.json::<User>().await.map_err(|e| e.to_string())?;
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
pub fn get_mobi_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Mobi::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_data(app: tauri::AppHandle, path: &Path) -> Result<BookData, String> {
    let data = Djvu::new(path);
    store_book_data(app, &data).map_err(|e| e.to_string())?;
    data.extract().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_page(path: &Path, page_number: u32, dpi: u32) -> Result<Vec<u8>, String> {
    crate::djvu::render_page_to_png(path, page_number, dpi).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_page_count(path: &Path) -> Result<u32, String> {
    crate::djvu::get_page_count(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_djvu_page_text(path: &Path, page_number: u32) -> Result<Vec<String>, String> {
    crate::djvu::get_page_text(path, page_number).map_err(|e| e.to_string())
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
pub fn get_mobi_chapter(path: &Path, chapter_index: u32) -> Result<String, String> {
    crate::mobi::get_chapter(path, chapter_index).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_mobi_chapter_count(path: &Path) -> Result<u32, String> {
    crate::mobi::get_chapter_count(path).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn get_mobi_text(path: &Path, chapter_index: u32) -> Result<Vec<String>, String> {
    crate::mobi::get_chapter_text(path, chapter_index).map_err(|e| e.to_string())
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
    fs::create_dir_all(output_dir).map_err(|e| e.to_string())?;

    // Extract all files (like AdmZip's `extractAllTo`)
    let canonical_output_dir = fs::canonicalize(output_dir).map_err(|e| e.to_string())?;
    for i in 0..archive.len() {
        let mut file = archive.by_index(i).map_err(|e| e.to_string())?;

        // Use enclosed_name() to prevent Zip Slip path traversal
        let entry_name = match file.enclosed_name() {
            Some(name) => name.to_owned(),
            None => {
                // Skip entries with unsafe paths (e.g., containing "..")
                continue;
            }
        };
        let outpath = output_dir.join(&entry_name);

        // Double-check the resolved path stays within output_dir
        if let Ok(canonical) = fs::canonicalize(outpath.parent().unwrap_or(output_dir)) {
            if !canonical.starts_with(&canonical_output_dir) {
                continue;
            }
        }

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
