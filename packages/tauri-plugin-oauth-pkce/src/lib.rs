mod config;
mod pkce;
mod keychain;
mod commands;

pub use config::OAuthConfig;

use tauri::plugin::{Builder, TauriPlugin};
use tauri::{Manager, Runtime};
use tauri_plugin_store::StoreExt;

/// Initialize the OAuth PKCE plugin with the given configuration.
pub fn init<R: Runtime>(config: OAuthConfig) -> TauriPlugin<R> {
    Builder::<R>::new("oauth-pkce")
        .setup(move |app, _api| {
            // Make config available as managed state for commands
            app.manage(config.clone());

            // Clean up stale OAuth state on startup
            if let Ok(store) = app.store("oauth-pkce-store.json") {
                let stale = store
                    .get("auth_state_created_at")
                    .and_then(|v| v.as_u64())
                    .map(|created| {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        let ttl_ms = app.state::<OAuthConfig>().state_ttl_secs * 1000;
                        now.saturating_sub(created) > ttl_ms
                    })
                    .unwrap_or(false);
                if stale {
                    store.delete("auth_state");
                    store.delete("auth_code_verifier");
                    store.delete("auth_state_created_at");
                    let _ = store.save();
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::complete_auth,
            commands::check_auth_status,
            commands::get_token,
            commands::sign_out,
            commands::get_user,
        ])
        .build()
}
