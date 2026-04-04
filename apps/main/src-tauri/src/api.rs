#[tauri::command]
pub async fn get_realtime_client_secret() -> Result<String, String> {
    let url = "https://rishi-worker.faridmato90.workers.dev/api/realtime/client_secrets";
    let client_secret = reqwest::get(url)
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
        let client_secret = get_realtime_client_secret().await.unwrap();
        println!("Client secret: {}", client_secret);
    }
}
