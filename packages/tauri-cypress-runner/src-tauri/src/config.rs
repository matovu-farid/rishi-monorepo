use crate::types::RunnerConfig;

pub fn load_config(path: &str) -> Result<RunnerConfig, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    serde_json::from_str(&content).map_err(|e| e.to_string())
}
