use tauri::command;
use crate::types::{RunnerConfig, TestFile};

#[command]
pub async fn get_config() -> Result<RunnerConfig, String> {
    Ok(RunnerConfig::default())
}

#[command]
pub async fn get_test_files() -> Result<Vec<TestFile>, String> {
    Ok(vec![])
}
