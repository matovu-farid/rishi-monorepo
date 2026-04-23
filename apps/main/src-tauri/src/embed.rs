use std::collections::HashMap;
use std::sync::Arc;

use embed_anything::embeddings::embed::{EmbedData, Embedder, EmbedderBuilder};
use embed_anything::process_chunks;
use serde::{Deserialize, Serialize};
use tokio::sync::OnceCell;

/// Lazy singleton for the embedding model.
/// Downloaded from HuggingFace on first use and cached in ~/.cache/huggingface/.
/// Using a singleton avoids re-downloading on every call and prevents lock
/// contention when multiple embed requests fire concurrently.
static EMBEDDER: OnceCell<Arc<Embedder>> = OnceCell::const_new();

async fn get_or_init_embedder() -> Result<Arc<Embedder>, String> {
    EMBEDDER
        .get_or_try_init(|| async {
            let embedder = EmbedderBuilder::new()
                .model_architecture("bert")
                .model_id(Some("sentence-transformers/all-MiniLM-L6-v2"))
                .from_pretrained_hf()
                .map_err(|e| format!("Failed to load embedding model: {}", e))?;
            Ok(Arc::new(embedder))
        })
        .await
        .cloned()
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Metadata {
    pub id: u64,
    pub page_number: usize,
    pub book_id: u32,
}

impl TryFrom<HashMap<String, String>> for Metadata {
    type Error = String;

    fn try_from(data: HashMap<String, String>) -> Result<Self, String> {
        Ok(Self {
            id: data
                .get("id")
                .ok_or("Missing 'id' in metadata")?
                .parse()
                .map_err(|e| format!("Failed to parse 'id': {}", e))?,
            page_number: data
                .get("page_number")
                .ok_or("Missing 'page_number' in metadata")?
                .parse()
                .map_err(|e| format!("Failed to parse 'page_number': {}", e))?,
            book_id: data
                .get("book_id")
                .unwrap_or(&"0".to_string())
                .parse()
                .map_err(|e| format!("Failed to parse 'book_id': {}", e))?,
        })
    }
}

impl From<Metadata> for HashMap<String, String> {
    fn from(data: Metadata) -> Self {
        HashMap::from([
            ("id".to_string(), data.id.to_string()),
            ("page_number".to_string(), data.page_number.to_string()),
            ("book_id".to_string(), data.book_id.to_string()),
        ])
    }
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EmbedResult {
    pub dim: usize,
    pub embedding: Vec<f32>,
    pub text: Option<String>,
    pub metadata: Metadata,
}

impl TryFrom<EmbedData> for EmbedResult {
    type Error = String;

    fn try_from(data: EmbedData) -> Result<Self, String> {
        let embedding = data
            .embedding
            .to_dense()
            .map_err(|e| format!("Failed to convert embedding to dense vector: {}", e))?;
        let metadata: Metadata = data
            .metadata
            .ok_or("Missing metadata in embed data")?
            .try_into()?;
        Ok(Self {
            dim: embedding.len(),
            embedding,
            text: data.text,
            metadata,
        })
    }
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct EmbedParam {
    pub text: String,
    pub metadata: Metadata,
}

pub async fn embed_text(embedparams: Vec<EmbedParam>) -> Result<Vec<EmbedResult>, String> {
    let embedding_model = get_or_init_embedder().await?;

    let chunks = embedparams
        .iter()
        .map(|p| p.text.clone())
        .collect::<Vec<_>>();
    let metadata = embedparams
        .iter()
        .map(|p| Some(p.metadata.clone().into()))
        .collect::<Vec<_>>();

    let embeddings = process_chunks(&chunks, &metadata, &embedding_model, Some(1), None)
        .await
        .map_err(|e| {
            sentry::capture_message(
                &format!("Embedding failed: {}", e),
                sentry::Level::Error,
            );
            e.to_string()
        })?;

    let res = Arc::into_inner(embeddings).ok_or("Failed to get embeddings")?;
    res.into_iter()
        .map(EmbedResult::try_from)
        .collect::<Result<Vec<_>, _>>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_embed_text() {
        let mut embedparams = vec![];
        for _ in 0..10 {
            embedparams.push(EmbedParam {
                text: "Chapter 4. Logical Components: The Building Blocks↵Ready to start creating an architecture? It's not as easy as it sounds—and if you don'…".to_string(),
                metadata: Metadata {
                    id: 7271375624100750,
                    page_number: 11,
                    book_id: 1,
                },
            });
        }
        let res = embed_text(embedparams).await.unwrap();

        assert!(!res.is_empty());
    }
}
