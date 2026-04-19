use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TestFile {
    pub path: String,
    pub name: String,
    pub last_modified: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RunnerConfig {
    pub tauri_dir: String,
    pub build_command: String,
    pub binary_path: String,
    pub spec_pattern: String,
    pub control_port: u16,
    pub default_command_timeout: u64,
    pub exec_timeout: u64,
    pub screenshots_folder: String,
    pub snapshots_folder: String,
    #[serde(default)]
    pub env: std::collections::HashMap<String, String>,
}
