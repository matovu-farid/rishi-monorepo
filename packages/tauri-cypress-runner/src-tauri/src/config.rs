use crate::types::RunnerConfig;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigFile {
    #[serde(default = "default_tauri_dir")]
    tauri_dir: String,
    #[serde(default = "default_build_command")]
    build_command: String,
    #[serde(default)]
    binary_path: String,
    #[serde(default = "default_spec_pattern")]
    spec_pattern: String,
    #[serde(default = "default_control_port")]
    control_port: u16,
    #[serde(default = "default_command_timeout")]
    default_command_timeout: u64,
    #[serde(default = "default_exec_timeout")]
    exec_timeout: u64,
    #[serde(default = "default_screenshots_folder")]
    screenshots_folder: String,
    #[serde(default = "default_snapshots_folder")]
    snapshots_folder: String,
    #[serde(default)]
    env: std::collections::HashMap<String, String>,
}

fn default_tauri_dir() -> String { "./src-tauri".to_string() }
fn default_build_command() -> String { "cargo build --features test-harness".to_string() }
fn default_spec_pattern() -> String { "cypress/**/*.cy.{ts,js}".to_string() }
fn default_control_port() -> u16 { 9223 }
fn default_command_timeout() -> u64 { 4000 }
fn default_exec_timeout() -> u64 { 60000 }
fn default_screenshots_folder() -> String { "cypress/screenshots".to_string() }
fn default_snapshots_folder() -> String { "cypress/snapshots".to_string() }

pub fn load_config(path: &str) -> Result<RunnerConfig, String> {
    let content = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let file: ConfigFile = serde_json::from_str(&content).map_err(|e| e.to_string())?;
    Ok(RunnerConfig {
        tauri_dir: file.tauri_dir,
        build_command: file.build_command,
        binary_path: file.binary_path,
        spec_pattern: file.spec_pattern,
        control_port: file.control_port,
        default_command_timeout: file.default_command_timeout,
        exec_timeout: file.exec_timeout,
        screenshots_folder: file.screenshots_folder,
        snapshots_folder: file.snapshots_folder,
        env: file.env,
    })
}
