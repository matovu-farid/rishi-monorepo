mod commands;
pub mod embed;
mod epub;
mod pdf;
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

use sentry;
use tauri_plugin_sentry;

#[cfg(test)]
pub mod test_fixtures;

#[cfg(test)]
pub mod test_helpers;

// Learn more about Tauri commands at https://tauri.app/develop/calling-rust/

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let client = sentry::init((
        "https://e67d34cb7b6a7fa22a04e39ab2100227@o4510586781958144.ingest.de.sentry.io/4510588300361808",
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
            //let _conn = db::init_database(app.handle())?;
            db::setup_database(app.handle())?;
            // You can store this conn somewhere global if needed
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::is_dev,
            commands::unzip,
            commands::get_book_data,
            commands::get_pdf_data,
            commands::embed,
            commands::save_vectors,
            commands::search_vectors,
            commands::process_job,
            commands::get_context_for_query,
            commands::get_state,
            commands::get_user,
            commands::signout,
            commands::get_user_from_store,
            commands::poll_for_user,
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
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
