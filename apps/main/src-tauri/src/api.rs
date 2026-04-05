#[tauri::command]
pub async fn get_realtime_client_secret(app: tauri::AppHandle) -> Result<String, String> {
    let url = "https://rishi-worker.faridmato90.workers.dev/api/realtime/client_secrets";
    let token = crate::commands::get_auth_token(&app)?;
    let client = reqwest::Client::new();
    let client_secret = client
        .get(url)
        .header("Authorization", format!("Bearer {}", token))
        .send()
        .await
        .map_err(|e| e.to_string())?
        .text()
        .await
        .map_err(|e| e.to_string())?;
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
