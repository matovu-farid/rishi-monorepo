use tauri_cypress_runner::config::load_config;
use std::io::Write;

#[test]
fn test_load_config_from_json() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("tauri-cypress.config.json");
    let mut file = std::fs::File::create(&config_path).unwrap();
    write!(file, r#"{{"tauriDir":"./src-tauri","buildCommand":"cargo build --features test-harness","binaryPath":"./target/debug/my-app","specPattern":"tests/**/*.cy.ts","controlPort":9999,"defaultCommandTimeout":5000,"execTimeout":30000,"screenshotsFolder":"screenshots","snapshotsFolder":"snapshots","env":{{"DB":"test.db"}}}}"#).unwrap();

    let config = load_config(config_path.to_str().unwrap()).unwrap();
    assert_eq!(config.tauri_dir, "./src-tauri");
    assert_eq!(config.binary_path, "./target/debug/my-app");
    assert_eq!(config.spec_pattern, "tests/**/*.cy.ts");
    assert_eq!(config.control_port, 9999);
    assert_eq!(config.default_command_timeout, 5000);
    assert_eq!(config.env.get("DB").unwrap(), "test.db");
}

#[test]
fn test_load_config_uses_defaults_for_missing_fields() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("tauri-cypress.config.json");
    let mut file = std::fs::File::create(&config_path).unwrap();
    write!(file, r#"{{}}"#).unwrap();

    let config = load_config(config_path.to_str().unwrap()).unwrap();
    assert_eq!(config.tauri_dir, "./src-tauri");
    assert_eq!(config.control_port, 9223);
    assert_eq!(config.default_command_timeout, 4000);
    assert_eq!(config.spec_pattern, "cypress/**/*.cy.{ts,js}");
}

#[test]
fn test_load_config_missing_file_returns_error() {
    let result = load_config("/nonexistent/path.json");
    assert!(result.is_err());
}
