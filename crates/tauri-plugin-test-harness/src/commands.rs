use tauri::{command, AppHandle, Runtime, Webview, Manager};
use crate::mock_registry::MockRegistry;
use crate::helper_registry::HelperRegistry;

#[command]
pub async fn register_mock<R: Runtime>(
    app: AppHandle<R>,
    command_name: String,
    response: serde_json::Value,
) -> std::result::Result<(), String> {
    let registry = app.state::<MockRegistry>();
    registry.register(&command_name, response);
    Ok(())
}

#[command]
pub async fn clear_mocks<R: Runtime>(
    app: AppHandle<R>,
) -> std::result::Result<(), String> {
    let registry = app.state::<MockRegistry>();
    registry.clear();
    Ok(())
}

#[command]
pub async fn call_helper<R: Runtime>(
    app: AppHandle<R>,
    name: String,
    args: Option<serde_json::Value>,
) -> std::result::Result<serde_json::Value, String> {
    let registry = app.state::<HelperRegistry>();
    registry
        .call(&name, args.unwrap_or(serde_json::Value::Null))
        .map_err(|e| e.to_string())
}

#[command]
pub async fn get_app_state<R: Runtime>(
    app: AppHandle<R>,
    key: String,
) -> std::result::Result<serde_json::Value, String> {
    match key.as_str() {
        "mocks" => {
            let registry = app.state::<MockRegistry>();
            Ok(serde_json::json!(registry.list()))
        }
        "helpers" => {
            let registry = app.state::<HelperRegistry>();
            Ok(serde_json::json!(registry.list()))
        }
        _ => Err(format!("Unknown state key: {}", key)),
    }
}

#[command]
pub async fn resize_window<R: Runtime>(
    webview: Webview<R>,
    width: f64,
    height: f64,
) -> std::result::Result<(), String> {
    let window = webview.window();
    window
        .set_size(tauri::Size::Logical(tauri::LogicalSize { width, height }))
        .map_err(|e| e.to_string())
}

#[command]
pub async fn minimize_window<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<(), String> {
    webview.window().minimize().map_err(|e| e.to_string())
}

#[command]
pub async fn maximize_window<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<(), String> {
    webview.window().maximize().map_err(|e| e.to_string())
}

#[command]
pub async fn fullscreen_window<R: Runtime>(
    webview: Webview<R>,
    fullscreen: bool,
) -> std::result::Result<(), String> {
    webview
        .window()
        .set_fullscreen(fullscreen)
        .map_err(|e| e.to_string())
}

#[command]
pub async fn get_window_position<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<serde_json::Value, String> {
    let pos = webview
        .window()
        .outer_position()
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({"x": pos.x, "y": pos.y}))
}

#[command]
pub async fn get_window_size<R: Runtime>(
    webview: Webview<R>,
) -> std::result::Result<serde_json::Value, String> {
    let size = webview
        .window()
        .outer_size()
        .map_err(|e| e.to_string())?;
    Ok(serde_json::json!({
        "width": size.width,
        "height": size.height,
    }))
}
