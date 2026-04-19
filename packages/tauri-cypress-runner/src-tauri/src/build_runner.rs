use log::{error, info};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use tauri::{AppHandle, Emitter, Runtime};

#[derive(serde::Serialize, Clone)]
struct BuildOutput { line: String, stream: String }

#[derive(serde::Serialize, Clone)]
struct BuildComplete { success: bool, exit_code: Option<i32> }

pub fn run_build<R: Runtime>(build_command: &str, working_dir: &str, app: AppHandle<R>) -> Result<(), String> {
    info!("Running build: {}", build_command);
    let parts: Vec<&str> = build_command.split_whitespace().collect();
    if parts.is_empty() { return Err("Empty build command".to_string()); }

    let mut cmd = Command::new(parts[0]);
    if parts.len() > 1 { cmd.args(&parts[1..]); }
    cmd.current_dir(working_dir).stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("Failed to start build: {}", e))?;

    if let Some(stdout) = child.stdout.take() {
        let app_c = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().flatten() {
                let _ = app_c.emit("test-harness://build-output", BuildOutput { line, stream: "stdout".to_string() });
            }
        });
    }

    if let Some(stderr) = child.stderr.take() {
        let app_c = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().flatten() {
                let _ = app_c.emit("test-harness://build-output", BuildOutput { line, stream: "stderr".to_string() });
            }
        });
    }

    let status = child.wait().map_err(|e| e.to_string())?;
    let success = status.success();
    let _ = app.emit("test-harness://build-complete", BuildComplete { success, exit_code: status.code() });

    if success { info!("Build succeeded"); Ok(()) }
    else { let msg = format!("Build failed (exit {})", status.code().unwrap_or(-1)); error!("{}", msg); Err(msg) }
}
