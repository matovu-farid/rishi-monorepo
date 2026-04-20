use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TestFile {
    pub path: String,
    pub name: String,
    pub last_modified: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RunnerConfig {
    pub tauri_dir: String,
    #[serde(default)]
    pub frontend_build_command: String,
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

impl Default for RunnerConfig {
    fn default() -> Self {
        Self {
            tauri_dir: "./src-tauri".to_string(),
            frontend_build_command: "pnpm build".to_string(),
            build_command: "cargo build --features test-harness".to_string(),
            binary_path: String::new(),
            spec_pattern: "cypress/**/*.cy.{ts,js}".to_string(),
            control_port: 9223,
            default_command_timeout: 4000,
            exec_timeout: 60000,
            screenshots_folder: "cypress/screenshots".to_string(),
            snapshots_folder: "cypress/snapshots".to_string(),
            env: std::collections::HashMap::new(),
        }
    }
}
