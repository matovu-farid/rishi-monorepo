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
            .expect("MockRegistry lock poisoned")
            .insert(command.to_string(), response);
    }

    pub fn get(&self, command: &str) -> Option<serde_json::Value> {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .get(command)
            .cloned()
    }

    pub fn has(&self, command: &str) -> bool {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .contains_key(command)
    }

    pub fn remove(&self, command: &str) {
        self.mocks
            .write()
            .expect("MockRegistry lock poisoned")
            .remove(command);
    }

    pub fn clear(&self) {
        self.mocks
            .write()
            .expect("MockRegistry lock poisoned")
            .clear();
    }

    pub fn list(&self) -> Vec<String> {
        self.mocks
            .read()
            .expect("MockRegistry lock poisoned")
            .keys()
            .cloned()
            .collect()
    }
}
