mod config;
mod pkce;
mod keychain;
mod commands;

pub use config::OAuthConfig;

use tauri::plugin::{Builder, TauriPlugin};
use tauri::Runtime;

pub fn init<R: Runtime>(config: OAuthConfig) -> TauriPlugin<R> {
    Builder::new("oauth-pkce")
        .build()
}
