use tauri::{command, AppHandle, Manager, Runtime};
use tokio::sync::Mutex;
use crate::{build_runner, config, process::AppProcess, test_discovery, types::{RunnerConfig, TestFile}, websocket_client::WsClient};

pub struct RunnerState {
    pub config: Mutex<RunnerConfig>,
    pub process: Mutex<AppProcess>,
    pub ws_client: Mutex<WsClient>,
    pub project_dir: Mutex<String>,
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
    let app_clone = app.clone();
    tokio::task::spawn_blocking(move || build_runner::run_build(&config.build_command, &project_dir, app_clone))
        .await.map_err(|e| e.to_string())?
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
    app.state::<RunnerState>().process.lock().await.kill()
}

#[command]
pub async fn connect_ws<R: Runtime>(app: AppHandle<R>) -> Result<(), String> {
    let state = app.state::<RunnerState>();
    let port = state.config.lock().await.control_port;
    let result = state.ws_client.lock().await.connect(port, app.clone()).await;
    result
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
    drop(project_dir);
    let result = state.ws_client.lock().await.send_exec(&script, &file_path).await;
    result
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
        state.ws_client.lock().await.send_exec(&script, &file.path).await?;
    }
    Ok(())
}
