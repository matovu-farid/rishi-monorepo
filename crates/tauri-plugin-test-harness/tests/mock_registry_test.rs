use tauri_plugin_test_harness::mock_registry::MockRegistry;

#[test]
fn test_register_and_get_mock() {
    let registry = MockRegistry::new();
    let response = serde_json::json!({"title": "Mock Book"});
    registry.register("get_book_data", response.clone());
    let mock = registry.get("get_book_data");
    assert!(mock.is_some());
    assert_eq!(mock.unwrap(), response);
}

#[test]
fn test_get_nonexistent_mock_returns_none() {
    let registry = MockRegistry::new();
    assert!(registry.get("no_such_command").is_none());
}

#[test]
fn test_clear_removes_all_mocks() {
    let registry = MockRegistry::new();
    registry.register("cmd_a", serde_json::json!("a"));
    registry.register("cmd_b", serde_json::json!("b"));
    registry.clear();
    assert!(registry.get("cmd_a").is_none());
    assert!(registry.get("cmd_b").is_none());
}

#[test]
fn test_register_overwrites_existing_mock() {
    let registry = MockRegistry::new();
    registry.register("cmd", serde_json::json!("first"));
    registry.register("cmd", serde_json::json!("second"));
    assert_eq!(registry.get("cmd").unwrap(), serde_json::json!("second"));
}

#[test]
fn test_remove_single_mock() {
    let registry = MockRegistry::new();
    registry.register("cmd_a", serde_json::json!("a"));
    registry.register("cmd_b", serde_json::json!("b"));
    registry.remove("cmd_a");
    assert!(registry.get("cmd_a").is_none());
    assert!(registry.get("cmd_b").is_some());
}

#[test]
fn test_has_mock() {
    let registry = MockRegistry::new();
    assert!(!registry.has("cmd"));
    registry.register("cmd", serde_json::json!(null));
    assert!(registry.has("cmd"));
}

#[test]
fn test_list_mocked_commands() {
    let registry = MockRegistry::new();
    registry.register("cmd_b", serde_json::json!("b"));
    registry.register("cmd_a", serde_json::json!("a"));
    let mut commands = registry.list();
    commands.sort();
    assert_eq!(commands, vec!["cmd_a", "cmd_b"]);
}

#[test]
fn test_registry_is_thread_safe() {
    use std::sync::Arc;
    use std::thread;
    let registry = Arc::new(MockRegistry::new());
    let mut handles = vec![];
    for i in 0..10 {
        let reg = Arc::clone(&registry);
        handles.push(thread::spawn(move || {
            let name = format!("cmd_{}", i);
            reg.register(&name, serde_json::json!(i));
        }));
    }
    for handle in handles {
        handle.join().unwrap();
    }
    assert_eq!(registry.list().len(), 10);
}
