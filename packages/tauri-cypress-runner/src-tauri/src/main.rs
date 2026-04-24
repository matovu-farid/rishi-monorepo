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

                // Serve the runner's own frontend on port 1421.
                // The Tauri webview loads from devUrl (http://localhost:1421)
                // so we need a static server for the built dist/ assets.
                let runner_dist = concat!(env!("CARGO_MANIFEST_DIR"), "/../dist");
                let runner_dist = std::fs::canonicalize(runner_dist)
                    .unwrap_or_else(|_| std::path::PathBuf::from(runner_dist));

                let _frontend_server = std::process::Command::new("sh")
                    .arg("-c")
                    .arg("npx serve . -l 1421 -s --no-clipboard")
                    .current_dir(&runner_dist)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .spawn()
                    .expect("Failed to start frontend server on port 1421");

                // Wait for the server to be ready
                for i in 0..20 {
                    if std::net::TcpStream::connect("127.0.0.1:1421").is_ok() {
                        break;
                    }
                    if i == 19 {
                        eprintln!("Warning: frontend server on :1421 not ready after 10s");
                    }
                    std::thread::sleep(std::time::Duration::from_millis(500));
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
