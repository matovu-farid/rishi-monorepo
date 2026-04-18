const COMMANDS: &[&str] = &[
    "register_mock",
    "clear_mocks",
    "call_helper",
    "get_app_state",
    "resize_window",
    "minimize_window",
    "maximize_window",
    "fullscreen_window",
    "get_window_position",
    "get_window_size",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).build();
}
