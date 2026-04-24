use std::collections::HashMap;
use std::sync::RwLock;

/// Thread-safe registry for storing command mock responses.
pub struct MockRegistry {
    mocks: RwLock<HashMap<String, serde_json::Value>>,
}

impl MockRegistry {
    pub fn new() -> Self {
        Self {
            mocks: RwLock::new(HashMap::new()),
        }
    }

    pub fn register(&self, command: &str, response: serde_json::Value) {
        self.mocks
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(command.to_string(), response);
    }

    pub fn get(&self, command: &str) -> Option<serde_json::Value> {
        self.mocks
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .get(command)
            .cloned()
    }

    pub fn has(&self, command: &str) -> bool {
        self.mocks
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(command)
    }

    pub fn remove(&self, command: &str) {
        self.mocks
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .remove(command);
    }

    pub fn clear(&self) {
        self.mocks
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .clear();
    }

    pub fn list(&self) -> Vec<String> {
        self.mocks
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect()
    }
}
