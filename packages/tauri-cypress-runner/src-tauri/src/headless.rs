use crate::{config, process::AppProcess, test_discovery};
use crate::types::RunnerConfig;
use serde::Deserialize;
use std::time::Instant;
use tokio::sync::mpsc;

/// Maximum number of WebSocket connection attempts before giving up.
const WS_MAX_RETRIES: u32 = 10;
/// Delay between WebSocket connection retry attempts (ms).
const WS_RETRY_DELAY_MS: u64 = 1000;

#[derive(Debug)]
pub struct TestOutcome {
    pub test_id: String,
    pub status: String,
    pub duration_ms: u64,
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TestResultData {
    test_id: String,
    status: String,
    error: Option<String>,
    duration_ms: u64,
}

pub async fn run_headless(project_dir: &str, config_path: Option<&str>) -> Result<i32, String> {
    // Load config
    let config = if let Some(path) = config_path {
        config::load_config(path)?
    } else {
        let default = format!("{}/tauri-cypress.config.json", project_dir);
        config::load_config(&default).unwrap_or_default()
    };

    println!("\n  tauri-cypress v0.1.0 — headless mode\n");

    // Discover tests
    let files = test_discovery::discover_tests(&config.spec_pattern, project_dir)?;
    if files.is_empty() {
        println!("  No test files found matching: {}", config.spec_pattern);
        return Ok(0);
    }
    println!("  Found {} test file(s)\n", files.len());

    // Build Rust backend (frontend is served by dev server in debug mode)
    println!("  Building backend...");
    let build_start = Instant::now();
    let tauri_dir = format!("{}/{}", project_dir, config.tauri_dir);
    run_build_sync(&config.build_command, &tauri_dir)?;
    println!(
        "  Build complete ({:.1}s)\n",
        build_start.elapsed().as_secs_f64()
    );

    // Build frontend to dist/ then serve it on :1420 (debug builds expect devUrl)
    println!("  Building frontend...");
    run_build_sync(&config.frontend_build_command, project_dir)?;

    println!("  Starting static server on :1420...");
    let dev_child = std::process::Command::new("sh")
        .arg("-c")
        .arg("npx serve dist -l 1420 -s --no-clipboard")
        .current_dir(project_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start static server: {}", e))?;
    let mut dev_server = Some(dev_child);
    for i in 0..30 {
        if std::net::TcpStream::connect("127.0.0.1:1420").is_ok() {
            println!("  Static server ready ({}s)", i + 1);
            break;
        }
        if i == 29 {
            if let Some(ref mut child) = dev_server {
                let _ = child.kill();
            }
            return Err("Static server failed to start within 30s".to_string());
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    }

    // Launch app
    println!("  Launching app...");
    let mut app_process = AppProcess::new();
    let binary = resolve_binary(&config, project_dir);
    app_process.spawn(&binary, &config.env)?;

    // Connect WebSocket with retry — the plugin's WS server starts asynchronously
    // during Tauri setup, so a fixed sleep is unreliable (especially on cold starts).
    println!(
        "  Connecting to WebSocket on port {}...",
        config.control_port
    );

    let url = format!("ws://127.0.0.1:{}", config.control_port);
    let ws_stream = connect_with_retry(&url, WS_MAX_RETRIES, WS_RETRY_DELAY_MS, &mut app_process).await?;

    let (result_tx, mut result_rx) = mpsc::channel::<TestOutcome>(256);

    use futures_util::{SinkExt, StreamExt};
    use tungstenite::protocol::Message;

    let (mut ws_write, mut ws_read) = ws_stream.split();

    // Spawn receiver task
    let tx = result_tx.clone();
    tokio::spawn(async move {
        while let Some(msg_result) = ws_read.next().await {
            let text = match msg_result {
                Ok(Message::Text(t)) => t,
                Ok(other) => { eprintln!("  [debug] non-text WS message: {:?}", other); continue; }
                Err(e) => { eprintln!("  [debug] WS read error: {}", e); break; }
            };
            eprintln!("  [debug] Received WS message: {}...", &text[..text.len().min(120)]);
            if let Ok(msg) = serde_json::from_str::<serde_json::Value>(&text) {
                if msg.get("type").and_then(|t| t.as_str()) == Some("result") {
                    if let Some(data) = msg.get("data") {
                        if let Ok(result) =
                            serde_json::from_value::<TestResultData>(data.clone())
                        {
                            let _ = tx
                                .send(TestOutcome {
                                    test_id: result.test_id,
                                    status: result.status,
                                    duration_ms: result.duration_ms,
                                    error: result.error,
                                })
                                .await;
                        }
                    }
                }
            }
        }
    });

    println!("  Connected. Running tests...\n");

    let mut outcomes: Vec<TestOutcome> = Vec::new();
    let run_start = Instant::now();

    // Run each test file.
    //
    // NOTE: Each file is sent as a single script and produces one result message.
    // If a file contains multiple `it()` blocks, the injector's `executeTestScript`
    // wraps the entire script in one try/catch — so the first failure aborts the
    // file and only one result is returned. Individual `it()` results would require
    // the test framework runtime to report them separately.
    for file in &files {
        let full_path = format!("{}/{}", project_dir, file.path);
        let script = std::fs::read_to_string(&full_path)
            .map_err(|e| format!("Failed to read {}: {}", full_path, e))?;

        // Strip TypeScript import lines that would cause SyntaxError in the
        // injector's dynamic evaluation. Test scripts use
        // `import { ... } from 'tauri-cypress'` but the injected runtime
        // already provides `__tauriCypress` as a function parameter.
        let script = strip_imports(&script);

        let msg = serde_json::json!({ "type": "exec", "script": script, "test_id": file.path });
        ws_write
            .send(Message::Text(msg.to_string()))
            .await
            .map_err(|e| format!("Send failed: {}", e))?;

        // Wait for result
        match tokio::time::timeout(
            tokio::time::Duration::from_millis(config.exec_timeout),
            result_rx.recv(),
        )
        .await
        {
            Ok(Some(outcome)) => {
                let icon = match outcome.status.as_str() {
                    "passed" => "\x1b[32m✓\x1b[0m",
                    "failed" => "\x1b[31m✗\x1b[0m",
                    _ => "\x1b[33m-\x1b[0m",
                };
                println!(
                    "  {} {} ({:.0}ms)",
                    icon, outcome.test_id, outcome.duration_ms
                );
                if let Some(ref err) = outcome.error {
                    println!("    \x1b[31m{}\x1b[0m", err);
                }
                outcomes.push(outcome);
            }
            Ok(None) => {
                println!("  \x1b[31m✗\x1b[0m {} (channel closed)", file.path);
                outcomes.push(TestOutcome {
                    test_id: file.path.clone(),
                    status: "failed".to_string(),
                    duration_ms: 0,
                    error: Some("Result channel closed".to_string()),
                });
            }
            Err(_) => {
                println!(
                    "  \x1b[31m✗\x1b[0m {} (timeout after {}ms)",
                    file.path, config.exec_timeout
                );
                outcomes.push(TestOutcome {
                    test_id: file.path.clone(),
                    status: "failed".to_string(),
                    duration_ms: config.exec_timeout,
                    error: Some(format!("Timeout after {}ms", config.exec_timeout)),
                });
            }
        }
    }

    let total_duration = run_start.elapsed();

    // Kill app and dev server
    let _ = app_process.kill();
    if let Some(ref mut child) = dev_server {
        let _ = child.kill();
        let _ = child.wait();
    }

    // Summary
    let passed = outcomes.iter().filter(|o| o.status == "passed").count();
    let failed = outcomes.iter().filter(|o| o.status == "failed").count();
    let skipped = outcomes.iter().filter(|o| o.status == "skipped").count();

    println!("\n  ────────────────────────────────────");
    println!(
        "  Tests:  {} passed, {} failed, {} skipped, {} total",
        passed,
        failed,
        skipped,
        outcomes.len()
    );
    println!("  Time:   {:.2}s", total_duration.as_secs_f64());
    println!("  ────────────────────────────────────\n");

    // Generate JUnit XML report
    let report_path = format!("{}/cypress/results/junit.xml", project_dir);
    generate_junit_xml(&outcomes, total_duration.as_secs_f64(), &report_path)?;
    println!("  JUnit report: {}\n", report_path);

    Ok(if failed > 0 { 1 } else { 0 })
}

/// Connect to the WebSocket server with retry.
/// Checks that the app process is still alive between attempts.
async fn connect_with_retry(
    url: &str,
    max_retries: u32,
    retry_delay_ms: u64,
    app_process: &mut AppProcess,
) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, String> {
    let mut last_err = String::new();
    for attempt in 0..max_retries {
        // Check that the app hasn't crashed before retrying
        if !app_process.is_running() {
            return Err("App process exited before WebSocket connection could be established".to_string());
        }

        match tokio_tungstenite::connect_async(url).await {
            Ok((stream, _)) => return Ok(stream),
            Err(e) => {
                last_err = e.to_string();
                if attempt + 1 < max_retries {
                    println!(
                        "  WebSocket not ready (attempt {}/{}), retrying in {}ms...",
                        attempt + 1,
                        max_retries,
                        retry_delay_ms
                    );
                    tokio::time::sleep(tokio::time::Duration::from_millis(retry_delay_ms)).await;
                }
            }
        }
    }
    Err(format!(
        "WebSocket connect failed after {} attempts: {}",
        max_retries, last_err
    ))
}

pub fn run_build_sync(build_command: &str, working_dir: &str) -> Result<(), String> {
    if build_command.is_empty() {
        return Err("Empty build command".to_string());
    }

    let mut cmd = std::process::Command::new("sh");
    cmd.arg("-c").arg(build_command);
    cmd.current_dir(working_dir);

    let status = cmd
        .status()
        .map_err(|e| format!("Build failed to start: {}", e))?;
    if !status.success() {
        return Err(format!(
            "Build failed with exit code: {}",
            status.code().unwrap_or(-1)
        ));
    }
    Ok(())
}

pub fn resolve_binary(config: &RunnerConfig, project_dir: &str) -> String {
    if !config.binary_path.is_empty() {
        if config.binary_path.starts_with("./") {
            format!("{}/{}", project_dir, &config.binary_path[2..])
        } else {
            config.binary_path.clone()
        }
    } else {
        // Infer the binary name from the Cargo.toml package name in tauri_dir.
        // Falls back to the directory name if Cargo.toml can't be read.
        let tauri_dir = if config.tauri_dir.starts_with("./") {
            format!("{}/{}", project_dir, &config.tauri_dir[2..])
        } else if config.tauri_dir.starts_with('/') {
            config.tauri_dir.clone()
        } else {
            format!("{}/{}", project_dir, config.tauri_dir)
        };

        let cargo_path = format!("{}/Cargo.toml", tauri_dir);
        let binary_name = std::fs::read_to_string(&cargo_path)
            .ok()
            .and_then(|content| {
                // Simple parse: find `name = "..."` under [package]
                let mut in_package = false;
                for line in content.lines() {
                    let trimmed = line.trim();
                    if trimmed.starts_with('[') {
                        in_package = trimmed == "[package]";
                        continue;
                    }
                    if in_package && trimmed.starts_with("name") {
                        if let Some(val) = trimmed.split('=').nth(1) {
                            let name = val.trim().trim_matches('"').trim_matches('\'');
                            if !name.is_empty() {
                                return Some(name.to_string());
                            }
                        }
                    }
                }
                None
            })
            .unwrap_or_else(|| {
                // Fall back to the project directory name
                std::path::Path::new(project_dir)
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            });

        format!("{}/target/debug/{}", project_dir, binary_name)
    }
}

/// Strip `import` and `export` statements from TypeScript test files.
///
/// Test scripts contain lines like `import { describe, it, cy } from 'tauri-cypress'`
/// which use ES module syntax. These cannot be evaluated inside the injector's
/// dynamic script evaluation because it is not a module context. The injected
/// runtime already provides `__tauriCypress` as a parameter, so the imports are
/// unnecessary at runtime.
///
/// This is a pragmatic pre-processor -- a full TypeScript compilation pipeline
/// would be more robust but is out of scope for v0.1.
pub fn strip_imports(script: &str) -> String {
    script
        .lines()
        .filter(|line| {
            let trimmed = line.trim();
            // Remove ES import/export statements
            !trimmed.starts_with("import ")
                && !trimmed.starts_with("export ")
                && !trimmed.starts_with("import{")
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn generate_junit_xml(
    outcomes: &[TestOutcome],
    total_time: f64,
    path: &str,
) -> Result<(), String> {
    let parent = std::path::Path::new(path).parent().unwrap();
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;

    let failed = outcomes.iter().filter(|o| o.status == "failed").count();

    let mut xml = String::new();
    xml.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    xml.push_str(&format!(
        "<testsuites name=\"tauri-cypress\" tests=\"{}\" failures=\"{}\" time=\"{:.3}\">\n",
        outcomes.len(),
        failed,
        total_time
    ));
    xml.push_str(&format!(
        "  <testsuite name=\"e2e\" tests=\"{}\" failures=\"{}\" time=\"{:.3}\">\n",
        outcomes.len(),
        failed,
        total_time
    ));

    for outcome in outcomes {
        let time_sec = outcome.duration_ms as f64 / 1000.0;
        xml.push_str(&format!(
            "    <testcase name=\"{}\" classname=\"tauri-cypress\" time=\"{:.3}\"",
            escape_xml(&outcome.test_id),
            time_sec
        ));

        if outcome.status == "failed" {
            xml.push_str(">\n");
            let err = outcome.error.as_deref().unwrap_or("Unknown error");
            xml.push_str(&format!(
                "      <failure message=\"{}\">{}</failure>\n",
                escape_xml(err),
                escape_xml(err)
            ));
            xml.push_str("    </testcase>\n");
        } else if outcome.status == "skipped" {
            xml.push_str(">\n      <skipped />\n    </testcase>\n");
        } else {
            xml.push_str(" />\n");
        }
    }

    xml.push_str("  </testsuite>\n</testsuites>\n");
    std::fs::write(path, &xml).map_err(|e| format!("Failed to write JUnit XML: {}", e))?;
    Ok(())
}

pub fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}
