pub mod build_runner;
pub mod commands;
pub mod config;
pub mod headless;
pub mod process;
pub mod screenshot;
pub mod test_discovery;
pub mod types;
pub mod websocket_client;

use commands::RunnerState;
use process::AppProcess;
use tokio::sync::Mutex;
use types::RunnerConfig;
use websocket_client::WsClient;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .manage(RunnerState {
            config: Mutex::new(RunnerConfig::default()),
            process: Mutex::new(AppProcess::new()),
            ws_client: Mutex::new(WsClient::new()),
            project_dir: Mutex::new(String::new()),
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_initial_project_dir,
            commands::start_session,
            commands::get_config,
            commands::get_test_files,
            commands::run_build,
            commands::launch_app,
            commands::stop_app,
            commands::connect_ws,
            commands::disconnect_ws,
            commands::run_test,
            commands::watch_tests,
            commands::run_all_tests,
            commands::save_baseline,
            commands::compare_screenshot,
            commands::update_baseline,
        ])
        .run(tauri::generate_context!())
        .expect("error running tauri-cypress-runner");
}
