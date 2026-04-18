use serde_json::json;
use tauri::Runtime;
use tauri_plugin_store::StoreExt;

use crate::config::OAuthConfig;
use crate::keychain;
use crate::pkce;

/// Response from get_state: the state UUID and its corresponding code_challenge.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthStateResponse {
    pub state: String,
    pub code_challenge: String,
}

/// Response from check_auth_status.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatusResponse {
    pub status: Option<String>,
    pub retry_count: Option<u32>,
    pub created_at: Option<u64>,
    pub error: Option<String>,
}

/// Response from complete_auth.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AuthCompleteResponse {
    pub token: String,
    pub expires_at: i64,
    pub user: serde_json::Value,
}

/// Generate a fresh OAuth state + PKCE code_challenge pair.
/// Persists the code_verifier in the Tauri store (never exposed to JS).
#[tauri::command]
pub fn get_state<R: Runtime>(app: tauri::AppHandle<R>, config: tauri::State<'_, OAuthConfig>) -> Result<OAuthStateResponse, String> {
    let _ = &config.scheme; // ensure config is used
    let state = uuid::Uuid::new_v4().to_string();
    let code_verifier = pkce::generate_code_verifier();

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.set("auth_state", json!(state));
    store.set("auth_code_verifier", json!(code_verifier));
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis() as u64;
    store.set("auth_state_created_at", json!(now_ms));
    store.save().map_err(|e| e.to_string())?;

    let code_challenge = pkce::compute_code_challenge(&code_verifier);

    Ok(OAuthStateResponse { state, code_challenge })
}

/// Complete the OAuth flow: sends state + code_verifier to the token endpoint,
/// stores the returned token in the OS keychain and user in the Tauri store.
#[tauri::command]
pub async fn complete_auth<R: Runtime>(app: tauri::AppHandle<R>, config: tauri::State<'_, OAuthConfig>, state: &str) -> Result<AuthCompleteResponse, String> {
    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;

    let code_verifier = store
        .get("auth_code_verifier")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .ok_or_else(|| "Missing code_verifier — please login again".to_string())?;

    let client = reqwest::Client::new();
    let response = client
        .post(&config.token_endpoint)
        .json(&json!({ "state": state, "code_verifier": code_verifier }))
        .send()
        .await
        .map_err(|e| format!("Network error calling token endpoint: {}", e))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Auth completion failed ({}): {}", status, body));
    }

    let exchange: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;

    let token = exchange["token"]
        .as_str()
        .ok_or("Missing token in response")?
        .to_string();
    let expires_at = exchange["expiresAt"]
        .as_i64()
        .or_else(|| exchange["expires_at"].as_i64())
        .unwrap_or(0);
    let user = exchange["user"].clone();

    // Store token in OS keychain
    keychain::set(&config.keyring_service, "auth_token", &token)?;
    keychain::set(&config.keyring_service, "auth_expires_at", &expires_at.to_string())?;

    // Store user (non-secret) in Tauri store
    store.set("user", user.clone());
    store.save().map_err(|e| e.to_string())?;

    Ok(AuthCompleteResponse { token, expires_at, user })
}

/// Check auth flow status from the status endpoint.
#[tauri::command]
pub async fn check_auth_status<R: Runtime>(app: tauri::AppHandle<R>, config: tauri::State<'_, OAuthConfig>, state: &str) -> Result<AuthStatusResponse, String> {
    let status_endpoint = config.status_endpoint.as_ref()
        .ok_or("No status_endpoint configured")?;

    uuid::Uuid::parse_str(state)
        .map_err(|_| "Invalid state parameter — expected UUID format".to_string())?;

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    let code_verifier = store
        .get("auth_code_verifier")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .ok_or_else(|| "No code_verifier in store".to_string())?;

    let code_challenge = pkce::compute_code_challenge(&code_verifier);

    let url = format!("{}/{}", status_endpoint, state);
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

/// Retrieve the auth token from the OS keychain, checking expiry.
#[tauri::command]
pub fn get_token(config: tauri::State<'_, OAuthConfig>) -> Result<String, String> {
    if let Some(exp_str) = keychain::get(&config.keyring_service, "auth_expires_at")? {
        let expires_at: u64 = exp_str.parse().map_err(|_| "Invalid auth_expires_at format")?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        if now > expires_at {
            return Err("Token expired — please log in again".to_string());
        }
    }

    match keychain::get(&config.keyring_service, "auth_token")? {
        Some(token) => Ok(token),
        None => Err("Not authenticated".to_string()),
    }
}

/// Sign out: clear keychain, optionally revoke token on the server.
#[tauri::command]
pub async fn sign_out<R: Runtime>(app: tauri::AppHandle<R>, config: tauri::State<'_, OAuthConfig>) -> Result<(), String> {
    // Best-effort server-side revocation
    if let Some(revoke_url) = &config.revoke_endpoint {
        if let Some(token) = keychain::get(&config.keyring_service, "auth_token")? {
            let client = reqwest::Client::new();
            let _ = client
                .post(revoke_url)
                .header("Authorization", format!("Bearer {}", token))
                .send()
                .await;
        }
    }

    keychain::delete(&config.keyring_service, "auth_token")?;
    keychain::delete(&config.keyring_service, "auth_expires_at")?;

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.delete("user");
    store.save().map_err(|e| e.to_string())?;

    Ok(())
}

/// Get the cached user from the Tauri store.
#[tauri::command]
pub fn get_user<R: Runtime>(app: tauri::AppHandle<R>) -> Result<serde_json::Value, String> {
    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.get("user").ok_or_else(|| "User not found".to_string())
}
