use tauri_plugin_test_harness::helper_registry::HelperRegistry;
use serde_json::json;

#[test]
fn test_register_and_call_helper() {
    let registry = HelperRegistry::new();
    registry.register("seedDatabase", |args| {
        let count = args["count"].as_u64().unwrap_or(0);
        Ok(json!({"seeded": count}))
    });
    let result = registry.call("seedDatabase", json!({"count": 5}));
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), json!({"seeded": 5}));
}

#[test]
fn test_call_nonexistent_helper_returns_error() {
    let registry = HelperRegistry::new();
    let result = registry.call("noSuchHelper", json!(null));
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("not found"));
}

#[test]
fn test_helper_that_returns_error() {
    let registry = HelperRegistry::new();
    registry.register("failingHelper", |_args| {
        Err("something went wrong".to_string())
    });
    let result = registry.call("failingHelper", json!(null));
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("something went wrong"));
}

#[test]
fn test_list_helpers() {
    let registry = HelperRegistry::new();
    registry.register("helperA", |_| Ok(json!(null)));
    registry.register("helperB", |_| Ok(json!(null)));
    let mut helpers = registry.list();
    helpers.sort();
    assert_eq!(helpers, vec!["helperA", "helperB"]);
}

#[test]
fn test_has_helper() {
    let registry = HelperRegistry::new();
    assert!(!registry.has("myHelper"));
    registry.register("myHelper", |_| Ok(json!(null)));
    assert!(registry.has("myHelper"));
}
