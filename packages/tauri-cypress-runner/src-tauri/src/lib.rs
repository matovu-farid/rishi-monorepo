pub mod commands;
pub mod config;
pub mod types;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_process::init())
        .invoke_handler(tauri::generate_handler![
            commands::get_config,
            commands::get_test_files,
        ])
        .run(tauri::generate_context!())
        .expect("error running tauri-cypress-runner");
}
