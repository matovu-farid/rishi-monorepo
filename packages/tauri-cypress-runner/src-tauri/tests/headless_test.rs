use tauri_cypress_runner::headless::{
    escape_xml, generate_junit_xml, resolve_binary, strip_imports, TestOutcome,
};
use tauri_cypress_runner::types::RunnerConfig;

// ── strip_imports ──────────────────────────────────────────────────

#[test]
fn test_strip_imports_removes_import_lines() {
    let script = r#"import { describe, it, cy } from 'tauri-cypress';
import{ foo } from 'bar';

describe('auth', () => {
  it('logs in', () => {
    cy.visit('/');
  });
});"#;

    let result = strip_imports(script);
    assert!(!result.contains("import "));
    assert!(!result.contains("import{"));
    assert!(result.contains("describe('auth'"));
    assert!(result.contains("cy.visit('/')"));
}

#[test]
fn test_strip_imports_removes_export_lines() {
    let script = r#"export default {};
export { foo };
const x = 42;"#;

    let result = strip_imports(script);
    assert!(!result.contains("export "));
    assert!(result.contains("const x = 42;"));
}

#[test]
fn test_strip_imports_preserves_non_import_lines() {
    let script = r#"const a = 1;
// This is a comment about imports
function test() { return true; }"#;

    let result = strip_imports(script);
    assert!(result.contains("const a = 1;"));
    assert!(result.contains("// This is a comment about imports"));
    assert!(result.contains("function test() { return true; }"));
}

#[test]
fn test_strip_imports_handles_empty_script() {
    let result = strip_imports("");
    assert_eq!(result, "");
}

// ── escape_xml ─────────────────────────────────────────────────────

#[test]
fn test_escape_xml_special_characters() {
    assert_eq!(escape_xml("&"), "&amp;");
    assert_eq!(escape_xml("<"), "&lt;");
    assert_eq!(escape_xml(">"), "&gt;");
    assert_eq!(escape_xml("\""), "&quot;");
    assert_eq!(escape_xml("'"), "&apos;");
    assert_eq!(
        escape_xml("a < b & c > d"),
        "a &lt; b &amp; c &gt; d"
    );
}

#[test]
fn test_escape_xml_no_special_characters() {
    assert_eq!(escape_xml("hello world"), "hello world");
}

// ── generate_junit_xml ─────────────────────────────────────────────

#[test]
fn test_generate_junit_xml_creates_valid_xml() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("results").join("junit.xml");
    let path_str = path.to_str().unwrap();

    let outcomes = vec![
        TestOutcome {
            test_id: "auth.cy.ts".to_string(),
            status: "passed".to_string(),
            duration_ms: 1200,
            error: None,
        },
        TestOutcome {
            test_id: "books.cy.ts".to_string(),
            status: "failed".to_string(),
            duration_ms: 500,
            error: Some("Element not found".to_string()),
        },
        TestOutcome {
            test_id: "settings.cy.ts".to_string(),
            status: "skipped".to_string(),
            duration_ms: 0,
            error: None,
        },
    ];

    generate_junit_xml(&outcomes, 1.7, path_str).unwrap();

    let xml = std::fs::read_to_string(path_str).unwrap();
    assert!(xml.starts_with("<?xml version=\"1.0\""));
    assert!(xml.contains("tests=\"3\""));
    assert!(xml.contains("failures=\"1\""));
    assert!(xml.contains("name=\"auth.cy.ts\""));
    assert!(xml.contains("<failure"));
    assert!(xml.contains("Element not found"));
    assert!(xml.contains("<skipped />"));
}

#[test]
fn test_generate_junit_xml_empty_outcomes() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("junit.xml");
    let path_str = path.to_str().unwrap();

    generate_junit_xml(&[], 0.0, path_str).unwrap();

    let xml = std::fs::read_to_string(path_str).unwrap();
    assert!(xml.contains("tests=\"0\""));
    assert!(xml.contains("failures=\"0\""));
}

#[test]
fn test_generate_junit_xml_escapes_special_chars() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("junit.xml");
    let path_str = path.to_str().unwrap();

    let outcomes = vec![TestOutcome {
        test_id: "test <special> & \"chars\"".to_string(),
        status: "failed".to_string(),
        duration_ms: 100,
        error: Some("Expected <div> to have attribute 'role'".to_string()),
    }];

    generate_junit_xml(&outcomes, 0.1, path_str).unwrap();

    let xml = std::fs::read_to_string(path_str).unwrap();
    // The test_id and error should be XML-escaped
    assert!(xml.contains("&lt;special&gt;"));
    assert!(xml.contains("&amp;"));
    assert!(xml.contains("&lt;div&gt;"));
}

// ── resolve_binary ─────────────────────────────────────────────────

#[test]
fn test_resolve_binary_with_explicit_relative_path() {
    let config = RunnerConfig {
        binary_path: "./target/debug/my-app".to_string(),
        ..Default::default()
    };
    let result = resolve_binary(&config, "/projects/my-app");
    assert_eq!(result, "/projects/my-app/target/debug/my-app");
}

#[test]
fn test_resolve_binary_with_explicit_absolute_path() {
    let config = RunnerConfig {
        binary_path: "/usr/local/bin/my-app".to_string(),
        ..Default::default()
    };
    let result = resolve_binary(&config, "/projects/my-app");
    assert_eq!(result, "/usr/local/bin/my-app");
}

#[test]
fn test_resolve_binary_infers_from_cargo_toml() {
    let dir = tempfile::tempdir().unwrap();
    let project_dir = dir.path().to_str().unwrap();

    // Create the src-tauri directory with a Cargo.toml
    let tauri_dir = dir.path().join("src-tauri");
    std::fs::create_dir_all(&tauri_dir).unwrap();
    std::fs::write(
        tauri_dir.join("Cargo.toml"),
        r#"[package]
name = "my-cool-app"
version = "0.1.0"
edition = "2021"
"#,
    )
    .unwrap();

    let config = RunnerConfig {
        binary_path: String::new(),
        tauri_dir: "./src-tauri".to_string(),
        ..Default::default()
    };
    let result = resolve_binary(&config, project_dir);
    assert_eq!(result, format!("{}/target/debug/my-cool-app", project_dir));
}

#[test]
fn test_resolve_binary_falls_back_to_dir_name() {
    let dir = tempfile::tempdir().unwrap();
    let project_dir = dir.path().to_str().unwrap();

    // tauri_dir does not have a Cargo.toml, so it falls back
    let config = RunnerConfig {
        binary_path: String::new(),
        tauri_dir: "./src-tauri".to_string(),
        ..Default::default()
    };
    let result = resolve_binary(&config, project_dir);

    // Should fall back to the project dir name
    let dir_name = dir.path().file_name().unwrap().to_string_lossy();
    assert_eq!(result, format!("{}/target/debug/{}", project_dir, dir_name));
}

// ── RunnerConfig defaults ──────────────────────────────────────────

#[test]
fn test_runner_config_defaults_are_sane() {
    let config = RunnerConfig::default();
    assert_eq!(config.tauri_dir, "./src-tauri");
    assert!(!config.build_command.is_empty());
    assert!(config.binary_path.is_empty());
    assert!(!config.spec_pattern.is_empty());
    assert!(config.control_port > 0);
    assert!(config.default_command_timeout > 0);
    assert!(config.exec_timeout > 0);
    assert!(config.env.is_empty());
}
