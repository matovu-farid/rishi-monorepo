use tauri::{command, AppHandle, Manager, Runtime};
use tokio::sync::Mutex;
use crate::{build_runner, config, headless, process::AppProcess, screenshot, test_discovery, types::{RunnerConfig, TestFile}, websocket_client::WsClient};

pub struct RunnerState {
    pub config: Mutex<RunnerConfig>,
    pub process: Mutex<AppProcess>,
    pub ws_client: Mutex<WsClient>,
    pub project_dir: Mutex<String>,
    pub frontend_server_pid: Mutex<Option<u32>>,
}

/// Get the project dir passed via CLI (env var set by main.rs)
#[command]
pub async fn get_initial_project_dir() -> Result<Option<String>, String> {
    Ok(std::env::var("TAURI_CYPRESS_PROJECT_DIR").ok())
}

#[command]
pub async fn start_session<R: Runtime>(app: AppHandle<R>, config_path: Option<String>, project_dir: String) -> Result<RunnerConfig, String> {
    let cfg = if let Some(path) = config_path {
        config::load_config(&path)?
    } else {
        let default_path = format!("{}/tauri-cypress.config.json", project_dir);
        config::load_config(&default_path).unwrap_or_default()
    };
    let state = app.state::<RunnerState>();
    *state.config.lock().await = cfg.clone();
    *state.project_dir.lock().await = project_dir;
    Ok(cfg)
}

#[command]
pub async fn get_config<R: Runtime>(app: AppHandle<R>) -> Result<RunnerConfig, String> {
    Ok(app.state::<RunnerState>().config.lock().await.clone())
}

#[command]
pub async fn get_test_files<R: Runtime>(app: AppHandle<R>) -> Result<Vec<TestFile>, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    test_discovery::discover_tests(&config.spec_pattern, &project_dir)
}

#[command]
pub async fn run_build<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    let tauri_dir = format!("{}/{}", project_dir, config.tauri_dir);
    let app_clone = app.clone();
    tokio::task::spawn_blocking(move || build_runner::run_build(&config.build_command, &tauri_dir, app_clone))
        .await.map_err(|e| e.to_string())?
}

/// Build the frontend (runs the frontend build command from config, e.g. `pnpm build`)
#[command]
pub async fn build_frontend<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    let app_clone = app.clone();
    tokio::task::spawn_blocking(move || build_runner::run_build(&config.frontend_build_command, &project_dir, app_clone))
        .await.map_err(|e| e.to_string())?
}

/// Kill any process listening on the given port
fn kill_port(port: u16) {
    let _ = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("lsof -ti:{} | xargs kill -9 2>/dev/null", port))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

/// Start a static file server for the built frontend on port 1420
#[command]
pub async fn start_frontend_server<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let project_dir = state.project_dir.lock().await.clone();

    // Kill any stale process on port 1420
    kill_port(1420);
    std::thread::sleep(std::time::Duration::from_millis(500));

    let child = std::process::Command::new("sh")
        .arg("-c")
        .arg("npx serve dist -l 1420 -s --no-clipboard")
        .current_dir(&project_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start frontend server: {}", e))?;

    // Track the PID for cleanup
    *state.frontend_server_pid.lock().await = Some(child.id());

    // Wait for server to be ready
    for i in 0..30 {
        if std::net::TcpStream::connect("127.0.0.1:1420").is_ok() {
            return Ok(());
        }
        if i == 29 {
            return Err("Frontend server on :1420 not ready after 15s".to_string());
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Ok(())
}

#[command]
pub async fn launch_app<R: Runtime>(app: AppHandle<R>) -> Result<u32, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    let binary = if config.binary_path.is_empty() {
        format!("{}/target/debug/tauri-cypress-app", project_dir)
    } else if config.binary_path.starts_with("./") {
        format!("{}/{}", project_dir, &config.binary_path[2..])
    } else {
        config.binary_path.clone()
    };
    let env = config.env.clone();
    drop(config);
    drop(project_dir);
    let result = state.process.lock().await.spawn(&binary, &env);
    result
}

#[command]
pub async fn stop_app<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    // Kill the app process
    state.process.lock().await.kill().ok();
    // Kill the frontend server
    if let Some(pid) = state.frontend_server_pid.lock().await.take() {
        let _ = std::process::Command::new("kill")
            .arg("-9")
            .arg(pid.to_string())
            .status();
    }
    // Also clean up the port in case it's stale
    kill_port(1420);
    Ok(())
}

#[command]
pub async fn connect_ws<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let port = state.config.lock().await.control_port;

    // Retry connection up to 10 times (the WS server starts asynchronously)
    let mut last_err = String::new();
    for attempt in 0..10 {
        match state.ws_client.lock().await.connect(port, app.clone()).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                last_err = e;
                if attempt < 9 {
                    tokio::time::sleep(tokio::time::Duration::from_secs(1)).await;
                }
            }
        }
    }
    Err(format!("WebSocket connect failed after 10 attempts: {}", last_err))
}

#[command]
pub async fn disconnect_ws<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    app.state::<RunnerState>().ws_client.lock().await.disconnect().await;
    Ok(())
}

#[command]
pub async fn run_test<R: Runtime>(app: AppHandle<R>, file_path: String) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let project_dir = state.project_dir.lock().await;
    let full_path = format!("{}/{}", project_dir, file_path);
    let script = std::fs::read_to_string(&full_path).map_err(|e| format!("Failed to read {}: {}", full_path, e))?;
    let script = headless::strip_imports(&script);
    drop(project_dir);
    let result = state.ws_client.lock().await.send_exec(&script, &file_path).await;
    result
}

#[command]
pub async fn watch_tests<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    test_discovery::watch_tests(&config.spec_pattern, &project_dir, app.clone())
}

#[command]
pub async fn run_all_tests<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await.clone();
    let project_dir = state.project_dir.lock().await.clone();
    let files = test_discovery::discover_tests(&config.spec_pattern, &project_dir)?;
    for file in files {
        let full_path = format!("{}/{}", project_dir, file.path);
        let script = std::fs::read_to_string(&full_path).map_err(|e| format!("Failed to read {}: {}", full_path, e))?;
        let script = headless::strip_imports(&script);
        state.ws_client.lock().await.send_exec(&script, &file.path).await?;
    }
    Ok(())
}

#[command]
pub async fn save_baseline<R: Runtime>(
    app: AppHandle<R>,
    base64_data: String,
    name: String,
) -> Result<String, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    let folder = format!("{}/{}/baselines", project_dir, config.screenshots_folder);
    screenshot::save_screenshot(&base64_data, &folder, &name)
}

#[command]
pub async fn compare_screenshot<R: Runtime>(
    app: AppHandle<R>,
    base64_data: String,
    name: String,
    threshold: Option<f64>,
) -> Result<screenshot::DiffResult, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    let baseline_folder = format!("{}/{}/baselines", project_dir, config.screenshots_folder);
    let diff_folder = format!("{}/{}/diffs", project_dir, config.screenshots_folder);
    let baseline = screenshot::baseline_path(&baseline_folder, &name);

    if !baseline.exists() {
        // No baseline -- save as new baseline automatically
        let path = screenshot::save_screenshot(&base64_data, &baseline_folder, &name)?;
        return Ok(screenshot::DiffResult {
            baseline_path: path,
            actual_path: String::new(),
            diff_path: None,
            match_percentage: 1.0,
            dimensions: (0, 0),
            diff_pixel_count: 0,
            passed: true,
            threshold: threshold.unwrap_or(0.99),
        });
    }

    screenshot::diff_screenshots(
        baseline.to_str().unwrap(),
        &base64_data,
        &diff_folder,
        &name,
        threshold.unwrap_or(0.99),
    )
}

#[command]
pub async fn update_baseline<R: Runtime>(
    app: AppHandle<R>,
    base64_data: String,
    name: String,
) -> Result<String, String> {
    let state = app.state::<RunnerState>();
    let config = state.config.lock().await;
    let project_dir = state.project_dir.lock().await;
    let folder = format!("{}/{}/baselines", project_dir, config.screenshots_folder);
    screenshot::save_screenshot(&base64_data, &folder, &name)
}

/// Save a debug HTML snapshot of the runner UI to disk for external screenshotting.
#[command]
pub async fn save_debug_html(filename: String, html: String) -> Result<String, String> {
    let dir = std::env::temp_dir().join("tauri-cypress-debug");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = dir.join(&filename);
    std::fs::write(&path, &html).map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().to_string())
}
