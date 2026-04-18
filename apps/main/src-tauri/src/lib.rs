pub(crate) mod commands;
pub mod embed;
mod epub;
mod pdf;
mod mobi;
pub(crate) mod djvu;
mod shared;
pub mod vectordb;

pub mod db;

pub mod llm;
pub mod models;
pub mod schema;
pub mod speach;
pub mod sql;

mod api;
mod user;

pub mod error_dump;
pub mod local_scanner;

pub const WORKER_URL: &str = "https://rishi-worker.faridmato90.workers.dev";


#[cfg(test)]
pub mod test_fixtures;

#[cfg(test)]
pub mod test_helpers;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let sentry_dsn = option_env!("SENTRY_DSN").unwrap_or(
        "https://e67d34cb7b6a7fa22a04e39ab2100227@o4510586781958144.ingest.de.sentry.io/4510588300361808",
    );
    let client = sentry::init((
        sentry_dsn,
        sentry::ClientOptions {
            release: sentry::release_name!(),
            enable_logs: true,
            auto_session_tracking: true,
            ..Default::default()
        },
    ));

    // Caution! Everything before here runs in both app and crash reporter processes
    #[cfg(not(target_os = "ios"))]
    let _guard = tauri_plugin_sentry::minidump::init(&client);
    // Everything after here runs in only the app process
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_sentry::init(&client))
        .plugin(tauri_plugin_sql::Builder::new().build())
        .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_http::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_mic_recorder::init())
        .setup(|app| {
            // Clear the error dump on every launch so it only contains
            // errors from the current session.
            error_dump::clear_on_launch();
            error_dump::clear_state_on_launch();

            db::setup_database(app.handle())?;
            // Migrate auth secrets from plain-text store.json to OS keychain
            if let Err(e) = commands::migrate_auth_to_keychain(app.handle()) {
                eprintln!("Keychain migration warning: {}", e);
            }
            // Clean up orphaned OAuth state older than Redis TTL (10 minutes)
            use tauri_plugin_store::StoreExt;
            if let Ok(store) = app.store("store.json") {
                let stale = store.get("auth_state_created_at")
                    .and_then(|v| v.as_u64())
                    .map(|created| {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        now.saturating_sub(created) > 10 * 60 * 1000 // 10 minutes
                    })
                    .unwrap_or(false);
                if stale {
                    store.delete("auth_state");
                    store.delete("auth_code_verifier");
                    store.delete("auth_state_created_at");
                    let _ = store.save();
                }
            }
            // Log deep-link arrivals at the Rust level so we can tell if
            // the URL reaches the process even when the JS listener misses it.
            // NOTE: This callback runs on the macOS event loop thread, NOT inside
            // a Tokio runtime — never call tokio::spawn or async code here.
            {
                use tauri::Listener;
                app.listen("deep-link://new-url", move |event| {
                    let payload = event.payload().to_string();
                    eprintln!("[deep-link] Rust listener received: {}", payload);
                });
            }
            // Auto-open devtools in debug builds so console output is visible
            // without remembering a shortcut. Compiled out of release builds.
            #[cfg(debug_assertions)]
            {
                use tauri::Manager;
                if let Some(window) = app.get_webview_window("main") {
                    window.open_devtools();
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::is_dev,
            commands::unzip,
            commands::get_book_data,
            commands::get_pdf_data,
            commands::get_mobi_data,
            commands::get_mobi_chapter,
            commands::get_mobi_chapter_count,
            commands::get_mobi_text,
            commands::get_djvu_data,
            commands::get_djvu_page,
            commands::get_djvu_page_count,
            commands::get_djvu_page_text,
            commands::embed,
            commands::save_vectors,
            commands::search_vectors,
            commands::process_job,
            commands::get_context_for_query,
            commands::get_state,
            commands::get_user,
            commands::signout,
            commands::get_user_from_store,
            commands::complete_auth,
            commands::check_auth_status,
            commands::get_auth_token_cmd,
            commands::log_auth_debug_cmd,
            commands::get_auth_debug,
            api::get_realtime_client_secret,
            // SQL commands
            sql::save_page_data_many,
            sql::get_all_page_data_by_book_id,
            sql::save_book,
            sql::get_book,
            sql::get_books,
            sql::delete_book,
            sql::update_book_cover,
            sql::has_saved_epub_data,
            sql::update_book_location,
            sql::get_text_from_vector_id,
            // Error dump commands (writes only in dev builds)
            error_dump::dump_error_cmd,
            error_dump::read_error_dump,
            error_dump::clear_error_dump,
            error_dump::dump_state_cmd,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
