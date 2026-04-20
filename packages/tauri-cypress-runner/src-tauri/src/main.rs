#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() > 1 {
        let mut config_path: Option<String> = None;
        let mut project_dir = std::env::current_dir()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        let command = args[1].as_str();

        let mut i = 2;
        while i < args.len() {
            match args[i].as_str() {
                "--config" if i + 1 < args.len() => {
                    config_path = Some(args[i + 1].clone());
                    i += 2;
                }
                arg if !arg.starts_with('-') => {
                    project_dir = std::fs::canonicalize(arg)
                        .unwrap_or_else(|_| std::path::PathBuf::from(arg))
                        .to_string_lossy()
                        .to_string();
                    i += 1;
                }
                _ => { i += 1; }
            }
        }

        match command {
            // Headless: tauri-cypress-runner run ./apps/main
            "run" => {
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
            // GUI: tauri-cypress-runner open ./apps/main
            "open" => {
                // Pass project dir to the GUI via env var
                std::env::set_var("TAURI_CYPRESS_PROJECT_DIR", &project_dir);
                if let Some(ref cfg) = config_path {
                    std::env::set_var("TAURI_CYPRESS_CONFIG_PATH", cfg);
                }
                tauri_cypress_runner::run();
            }
            _ => {
                eprintln!("Usage:");
                eprintln!("  tauri-cypress-runner open [project_dir]   # GUI mode");
                eprintln!("  tauri-cypress-runner run [project_dir]    # Headless/CI mode");
                std::process::exit(1);
            }
        }
    } else {
        eprintln!("Usage:");
        eprintln!("  tauri-cypress-runner open [project_dir]   # GUI mode");
        eprintln!("  tauri-cypress-runner run [project_dir]    # Headless/CI mode");
        std::process::exit(1);
    }
}
