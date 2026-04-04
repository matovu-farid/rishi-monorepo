use serde_json::json;

pub async fn tts(text: &str) -> anyhow::Result<Vec<u8>> {
    let client = reqwest::Client::new();

    let map = json!({
        "voice": "alloy",
        "input": text,
        "response_format": "mp3",
        "speed": 1.0
    });
    let response = client
        .post("https://rishi-worker.faridmato90.workers.dev/api/audio/speech")
        .json(&map)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to get response bytes: {}", e))?
        .bytes()
        .await?;

    let vec: Vec<u8> = response.to_vec();

    Ok(vec)
}

#[cfg(test)]
mod tests {
    use super::*;
    use expectest::prelude::*;

    #[tokio::test]
    async fn test_tts() {
        let text = "The quick brown fox jumps over the lazy dog.";
        let audio_data = tts(text).await.unwrap();
        println!(
            "audio_data: {:x?}",
            audio_data.iter().take(12).collect::<Vec<&u8>>()
        );
        expect!(audio_data.len()).not_to(be_equal_to(0));
    }
}
