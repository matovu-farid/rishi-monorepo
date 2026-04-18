/// Store a value in the OS keychain.
pub fn set(service: &str, key: &str, value: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(service, key).map_err(|e| e.to_string())?;
    entry.set_password(value).map_err(|e| e.to_string())
}

/// Read a value from the OS keychain. Returns None if not found.
pub fn get(service: &str, key: &str) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(service, key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(val) => Ok(Some(val)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

/// Delete a value from the OS keychain. Ignores "not found" errors.
pub fn delete(service: &str, key: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(service, key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
