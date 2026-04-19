#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // Check for headless mode: `tauri-cypress-runner run [--config path] [project_dir]`
    if args.len() > 1 && args[1] == "run" {
        let mut config_path: Option<String> = None;
        let mut project_dir = std::env::current_dir()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--config" if i + 1 < args.len() => {
                    config_path = Some(args[i + 1].clone());
                    i += 2;
                }
                arg if !arg.starts_with('-') => {
                    project_dir = arg.to_string();
                    i += 1;
                }
                _ => {
                    i += 1;
                }
            }
        }

        let rt = tokio::runtime::Runtime::new().expect("Failed to create tokio runtime");
        let exit_code = rt
            .block_on(tauri_cypress_runner::headless::run_headless(
                &project_dir,
                config_path.as_deref(),
            ))
            .unwrap_or_else(|e| {
                eprintln!("Error: {}", e);
                1
            });

        std::process::exit(exit_code);
    }

    // Default: launch GUI mode
    tauri_cypress_runner::run();
}
