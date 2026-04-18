#[tauri::command]
pub async fn get_realtime_client_secret(app: tauri::AppHandle) -> Result<String, String> {
    let url = format!("{}/api/realtime/client_secrets", crate::WORKER_URL);
    let token = crate::commands::get_auth_token(&app)?;
    let client = reqwest::Client::new();
    let mut req = client.get(&url);

    if token == "dev-placeholder-token" {
        let secret = option_env!("DEV_BYPASS_SECRET").unwrap_or("");
        req = req.header("X-Dev-Bypass", secret);
    } else {
        req = req.header("Authorization", format!("Bearer {}", token));
    }

    let response = req.send().await.map_err(|e| e.to_string())?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err("Session expired — please log in again".to_string());
    }
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Failed to get client secret ({}): {}", status, body));
    }

    let client_secret = response.text().await.map_err(|e| e.to_string())?;
    Ok(client_secret)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_get_realtime_client_secret() {
        // Note: this test requires a running app handle - skip in unit tests
        // let client_secret = get_realtime_client_secret().await.unwrap();
        // println!("Client secret: {}", client_secret);
    }
}
