use std::collections::HashMap;
use std::sync::RwLock;
use crate::error::Error;

type HelperFn = Box<
    dyn Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
        + Send
        + Sync,
>;

/// Registry for user-defined Rust helper functions.
pub struct HelperRegistry {
    helpers: RwLock<HashMap<String, HelperFn>>,
}

impl HelperRegistry {
    pub fn new() -> Self {
        Self {
            helpers: RwLock::new(HashMap::new()),
        }
    }

    pub fn register<F>(&self, name: &str, f: F)
    where
        F: Fn(serde_json::Value) -> std::result::Result<serde_json::Value, String>
            + Send
            + Sync
            + 'static,
    {
        self.helpers
            .write()
            .unwrap_or_else(|e| e.into_inner())
            .insert(name.to_string(), Box::new(f));
    }

    pub fn call(
        &self,
        name: &str,
        args: serde_json::Value,
    ) -> crate::Result<serde_json::Value> {
        let helpers = self.helpers.read().unwrap_or_else(|e| e.into_inner());
        let helper = helpers
            .get(name)
            .ok_or_else(|| Error::HelperNotFound(name.to_string()))?;
        helper(args).map_err(Error::HelperFailed)
    }

    pub fn has(&self, name: &str) -> bool {
        self.helpers
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .contains_key(name)
    }

    pub fn list(&self) -> Vec<String> {
        self.helpers
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .keys()
            .cloned()
            .collect()
    }
}
