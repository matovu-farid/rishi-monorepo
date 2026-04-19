use std::sync::Arc;
use tauri::{ipc::Invoke, Runtime};

use crate::mock_registry::MockRegistry;

/// Creates an invoke handler that checks the mock registry before passing
/// commands through to the app's real handlers.
///
/// **NOTE:** This function is not currently wired into the plugin. Tauri 2's
/// plugin `invoke_handler` expects `fn(Invoke<R>)` (no return value), and
/// there is no built-in pre-handler interception hook. IPC interception is
/// instead handled entirely on the JS side by the init script's monkey-patch
/// of `__TAURI_INTERNALS__.invoke` (see `injector.rs`).
///
/// This module is retained as a reference implementation for potential future
/// Rust-side interception via Tauri's `on_invoke` hook or similar mechanism.
///
/// Returns `true` if the command was intercepted (mocked), `false` to pass through.
pub fn create_invoke_handler<R: Runtime>(
    mock_registry: Arc<MockRegistry>,
) -> impl Fn(Invoke<R>) -> bool + Send + Sync + 'static {
    move |invoke: Invoke<R>| {
        let cmd = invoke.message.command();

        // Don't intercept our own plugin commands
        if cmd.starts_with("plugin:test-harness|") {
            return false;
        }

        // Check if this command has a mock registered
        if let Some(response) = mock_registry.get(cmd) {
            log::debug!("Intercepted command '{}' with mock response", cmd);
            invoke.resolver.resolve(response);
            return true;
        }

        // No mock, pass through to real handlers
        false
    }
}
