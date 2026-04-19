pub mod protocol;
pub mod error;
pub mod mock_registry;
pub mod helper_registry;
pub mod websocket;
pub mod injector;
pub mod commands;
pub mod interceptor;

pub use error::{Error, Result};
pub use protocol::*;

use tauri::{plugin::TauriPlugin, Manager, Runtime};
use mock_registry::MockRegistry;
use helper_registry::HelperRegistry;
use websocket::ControlChannel;

/// Default WebSocket port for the control channel.
pub const DEFAULT_PORT: u16 = 9223;

type HelperFnBox = Box<
    dyn Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
        + Send
        + Sync
        + 'static,
>;

/// Builder for configuring the test harness plugin.
pub struct PluginBuilder {
    port: u16,
    helpers: Vec<(String, HelperFnBox)>,
}

impl PluginBuilder {
    pub fn new() -> Self {
        Self {
            port: DEFAULT_PORT,
            helpers: Vec::new(),
        }
    }

    /// Set the WebSocket port for the control channel. Defaults to 9223.
    pub fn port(mut self, port: u16) -> Self {
        self.port = port;
        self
    }

    /// Register a Rust helper function callable from tests via `cy.rustHelper(name, args)`.
    pub fn helper<F>(mut self, name: &str, f: F) -> Self
    where
        F: Fn(serde_json::Value)
                -> std::result::Result<serde_json::Value, String>
            + Send
            + Sync
            + 'static,
    {
        self.helpers.push((name.to_string(), Box::new(f)));
        self
    }

    /// Build the Tauri plugin.
    pub fn build<R: Runtime>(self) -> TauriPlugin<R> {
        let port = self.port;
        let helpers = self.helpers;
        let init_script = injector::generate_init_script(port);

        tauri::plugin::Builder::<R>::new("test-harness")
            .js_init_script(init_script)
            .setup(move |app, _api| {
                app.manage(MockRegistry::new());

                let helper_registry = HelperRegistry::new();
                for (name, f) in helpers {
                    helper_registry.register(&name, f);
                }
                app.manage(helper_registry);

                let channel = ControlChannel::new();
                let channel_for_task = channel.clone();
                app.manage(channel);

                tauri::async_runtime::spawn(async move {
                    match channel_for_task
                        .start(&format!("127.0.0.1:{}", port))
                        .await
                    {
                        Ok(actual_port) => {
                            log::info!(
                                "Test harness control channel on port {}",
                                actual_port
                            );
                        }
                        Err(e) => {
                            log::error!(
                                "Failed to start test harness WebSocket: {}",
                                e
                            );
                        }
                    }
                });

                Ok(())
            })
            .invoke_handler(tauri::generate_handler![
                commands::register_mock,
                commands::clear_mocks,
                commands::call_helper,
                commands::get_app_state,
                commands::resize_window,
                commands::minimize_window,
                commands::maximize_window,
                commands::fullscreen_window,
                commands::get_window_position,
                commands::get_window_size,
            ])
            .build()
    }
}

impl Default for PluginBuilder {
    fn default() -> Self {
        Self::new()
    }
}

/// Create the plugin with default settings (no custom helpers, port 9223).
pub fn init<R: Runtime>() -> TauriPlugin<R> {
    PluginBuilder::new().build()
}
