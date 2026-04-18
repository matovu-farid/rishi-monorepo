use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OAuthConfig {
    pub scheme: String,
    pub token_endpoint: String,
    pub status_endpoint: Option<String>,
    pub revoke_endpoint: Option<String>,
    pub keyring_service: String,
    pub state_ttl_secs: u64,
}
