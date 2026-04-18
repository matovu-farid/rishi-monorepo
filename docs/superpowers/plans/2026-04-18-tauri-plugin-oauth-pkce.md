# tauri-plugin-oauth-pkce Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a reusable, provider-agnostic Tauri v2 plugin that handles desktop OAuth 2.0 PKCE flows — PKCE generation, deep-link callbacks, keychain storage, token exchange with retry, and state cleanup.

**Architecture:** A Tauri v2 plugin (`tauri-plugin-oauth-pkce`) with Rust backend handling PKCE, keychain, and HTTP, plus a framework-agnostic TypeScript `OAuthClient` class that orchestrates the full flow (browser open → deep-link listen → retry → events). Extracted from the existing implementation in `apps/main/`.

**Tech Stack:** Rust (Tauri v2 plugin system, keyring, sha2, uuid, reqwest), TypeScript (Tauri IPC invoke, deep-link plugin API)

---

## File Structure

```
packages/tauri-plugin-oauth-pkce/
├── Cargo.toml                 # Rust crate metadata and dependencies
├── src/
│   ├── lib.rs                 # Plugin builder, init(), command registration, state cleanup
│   ├── config.rs              # OAuthConfig struct
│   ├── pkce.rs                # PKCE code_verifier + code_challenge generation
│   ├── keychain.rs            # OS keychain helpers (set/get/delete)
│   └── commands.rs            # Tauri commands: get_state, complete_auth, check_auth_status, get_token, sign_out, get_user
├── js/
│   ├── package.json           # npm package: tauri-plugin-oauth-pkce
│   ├── tsconfig.json          # TypeScript config
│   └── src/
│       ├── index.ts           # Re-exports commands + OAuthClient
│       ├── commands.ts        # Typed invoke() wrappers for each Rust command
│       └── client.ts          # OAuthClient class: startFlow, deep-link listener, retry, events
└── README.md                  # Usage docs, backend API contract, provider examples
```

---

### Task 1: Scaffold Rust Crate

**Files:**
- Create: `packages/tauri-plugin-oauth-pkce/Cargo.toml`
- Create: `packages/tauri-plugin-oauth-pkce/src/lib.rs` (minimal placeholder)

- [ ] **Step 1: Create Cargo.toml**

```toml
[package]
name = "tauri-plugin-oauth-pkce"
version = "0.1.0"
edition = "2021"
description = "Provider-agnostic OAuth 2.0 PKCE plugin for Tauri v2 desktop apps"
license = "MIT"

[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-store = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
uuid = { version = "1", features = ["v4"] }
rand = "0.8"
base64 = "0.22"
sha2 = "0.10"
keyring = { version = "3", features = ["apple-native", "windows-native", "sync-secret-service"] }
reqwest = { version = "0.12", features = ["json"] }
```

- [ ] **Step 2: Create minimal lib.rs**

```rust
mod config;
mod pkce;
mod keychain;
mod commands;

pub use config::OAuthConfig;

use tauri::plugin::{Builder, TauriPlugin};
use tauri::Runtime;

pub fn init<R: Runtime>(config: OAuthConfig) -> TauriPlugin<R> {
    Builder::new("oauth-pkce")
        .build()
}
```

- [ ] **Step 3: Create empty module files**

Create these files with placeholder content so the crate compiles:

`packages/tauri-plugin-oauth-pkce/src/config.rs`:
```rust
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OAuthConfig {
    pub scheme: String,
    pub token_endpoint: String,
    pub status_endpoint: Option<String>,
    pub revoke_endpoint: Option<String>,
    pub keyring_service: String,
    pub state_ttl_secs: u64,
}
```

`packages/tauri-plugin-oauth-pkce/src/pkce.rs`:
```rust
// PKCE generation — implemented in Task 2
```

`packages/tauri-plugin-oauth-pkce/src/keychain.rs`:
```rust
// Keychain helpers — implemented in Task 3
```

`packages/tauri-plugin-oauth-pkce/src/commands.rs`:
```rust
// Tauri commands — implemented in Task 4
```

- [ ] **Step 4: Verify the crate compiles**

Run: `cd packages/tauri-plugin-oauth-pkce && cargo check`
Expected: compiles with no errors (warnings about unused imports are fine)

- [ ] **Step 5: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/Cargo.toml packages/tauri-plugin-oauth-pkce/src/
git commit -m "feat(tauri-plugin-oauth-pkce): scaffold Rust crate with config struct"
```

---

### Task 2: Implement PKCE Module

**Files:**
- Modify: `packages/tauri-plugin-oauth-pkce/src/pkce.rs`

- [ ] **Step 1: Implement PKCE generation**

Replace the contents of `pkce.rs`:

```rust
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};

/// Generate a cryptographically random code_verifier (32 bytes, base64url-encoded).
pub fn generate_code_verifier() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Compute code_challenge = hex(SHA-256(code_verifier)).
/// The hex encoding matches what the existing Rishi implementation uses.
pub fn compute_code_challenge(code_verifier: &str) -> String {
    let hash = Sha256::digest(code_verifier.as_bytes());
    hash.iter().map(|b| format!("{:02x}", b)).collect::<String>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifier_is_base64url_encoded() {
        let verifier = generate_code_verifier();
        // 32 bytes → 43 base64url chars (no padding)
        assert_eq!(verifier.len(), 43);
        assert!(verifier.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn two_verifiers_are_different() {
        let v1 = generate_code_verifier();
        let v2 = generate_code_verifier();
        assert_ne!(v1, v2);
    }

    #[test]
    fn challenge_is_hex_sha256() {
        let verifier = "test_verifier_value";
        let challenge = compute_code_challenge(verifier);
        // SHA-256 hex is always 64 chars
        assert_eq!(challenge.len(), 64);
        assert!(challenge.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn challenge_is_deterministic() {
        let verifier = "deterministic_test";
        let c1 = compute_code_challenge(verifier);
        let c2 = compute_code_challenge(verifier);
        assert_eq!(c1, c2);
    }
}
```

- [ ] **Step 2: Run tests**

Run: `cd packages/tauri-plugin-oauth-pkce && cargo test pkce`
Expected: 4 tests pass

- [ ] **Step 3: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/src/pkce.rs
git commit -m "feat(tauri-plugin-oauth-pkce): implement PKCE code_verifier and code_challenge generation"
```

---

### Task 3: Implement Keychain Module

**Files:**
- Modify: `packages/tauri-plugin-oauth-pkce/src/keychain.rs`

- [ ] **Step 1: Implement keychain helpers**

Replace the contents of `keychain.rs`:

```rust
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
```

- [ ] **Step 2: Verify crate compiles**

Run: `cd packages/tauri-plugin-oauth-pkce && cargo check`
Expected: compiles

- [ ] **Step 3: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/src/keychain.rs
git commit -m "feat(tauri-plugin-oauth-pkce): implement OS keychain helpers (set/get/delete)"
```

---

### Task 4: Implement Tauri Commands

**Files:**
- Modify: `packages/tauri-plugin-oauth-pkce/src/commands.rs`
- Modify: `packages/tauri-plugin-oauth-pkce/src/lib.rs`

- [ ] **Step 1: Implement all commands**

Replace the contents of `commands.rs`:

```rust
use serde_json::json;
use tauri_plugin_store::StoreExt;

use crate::config::OAuthConfig;
use crate::keychain;
use crate::pkce;

/// Response from get_state: the state UUID and its corresponding code_challenge.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct OAuthStateResponse {
    pub state: String,
    pub code_challenge: String,
}

/// Response from check_auth_status.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AuthStatusResponse {
    pub status: Option<String>,
    pub retry_count: Option<u32>,
    pub created_at: Option<u64>,
    pub error: Option<String>,
}

/// Response from complete_auth.
#[derive(serde::Serialize, serde::Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct AuthCompleteResponse {
    pub token: String,
    pub expires_at: i64,
    pub user: serde_json::Value,
}

/// Generate a fresh OAuth state + PKCE code_challenge pair.
/// Persists the code_verifier in the Tauri store (never exposed to JS).
#[tauri::command]
pub fn get_state(app: tauri::AppHandle, config: tauri::State<'_, OAuthConfig>) -> Result<OAuthStateResponse, String> {
    let state = uuid::Uuid::new_v4().to_string();
    let code_verifier = pkce::generate_code_verifier();

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.set("auth_state", json!(state));
    store.set("auth_code_verifier", json!(code_verifier));
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_millis() as u64;
    store.set("auth_state_created_at", json!(now_ms));
    store.save().map_err(|e| e.to_string())?;

    let code_challenge = pkce::compute_code_challenge(&code_verifier);

    Ok(OAuthStateResponse { state, code_challenge })
}

/// Complete the OAuth flow: sends state + code_verifier to the token endpoint,
/// stores the returned token in the OS keychain and user in the Tauri store.
#[tauri::command]
pub async fn complete_auth(app: tauri::AppHandle, config: tauri::State<'_, OAuthConfig>, state: &str) -> Result<AuthCompleteResponse, String> {
    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;

    let code_verifier = store
        .get("auth_code_verifier")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .ok_or_else(|| "Missing code_verifier — please login again".to_string())?;

    let client = reqwest::Client::new();
    let response = client
        .post(&config.token_endpoint)
        .json(&json!({ "state": state, "code_verifier": code_verifier }))
        .send()
        .await
        .map_err(|e| format!("Network error calling token endpoint: {}", e))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Auth completion failed ({}): {}", status, body));
    }

    let exchange: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;

    let token = exchange["token"]
        .as_str()
        .ok_or("Missing token in response")?
        .to_string();
    let expires_at = exchange["expiresAt"]
        .as_i64()
        .or_else(|| exchange["expires_at"].as_i64())
        .unwrap_or(0);
    let user = exchange["user"].clone();

    // Store token in OS keychain
    keychain::set(&config.keyring_service, "auth_token", &token)?;
    keychain::set(&config.keyring_service, "auth_expires_at", &expires_at.to_string())?;

    // Store user (non-secret) in Tauri store
    store.set("user", user.clone());
    store.save().map_err(|e| e.to_string())?;

    Ok(AuthCompleteResponse { token, expires_at, user })
}

/// Check auth flow status from the status endpoint.
#[tauri::command]
pub async fn check_auth_status(app: tauri::AppHandle, config: tauri::State<'_, OAuthConfig>, state: &str) -> Result<AuthStatusResponse, String> {
    let status_endpoint = config.status_endpoint.as_ref()
        .ok_or("No status_endpoint configured")?;

    uuid::Uuid::parse_str(state)
        .map_err(|_| "Invalid state parameter — expected UUID format".to_string())?;

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    let code_verifier = store
        .get("auth_code_verifier")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .ok_or_else(|| "No code_verifier in store".to_string())?;

    let code_challenge = pkce::compute_code_challenge(&code_verifier);

    let url = format!("{}/{}", status_endpoint, state);
    let client = reqwest::Client::new();
    let response = client
        .post(&url)
        .json(&json!({ "code_challenge": code_challenge }))
        .send()
        .await
        .map_err(|e| e.to_string())?;

    let value: AuthStatusResponse = response.json().await.map_err(|e| e.to_string())?;
    Ok(value)
}

/// Retrieve the auth token from the OS keychain, checking expiry.
#[tauri::command]
pub fn get_token(config: tauri::State<'_, OAuthConfig>) -> Result<String, String> {
    if let Some(exp_str) = keychain::get(&config.keyring_service, "auth_expires_at")? {
        let expires_at: u64 = exp_str.parse().map_err(|_| "Invalid auth_expires_at format")?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        if now > expires_at {
            return Err("Token expired — please log in again".to_string());
        }
    }

    match keychain::get(&config.keyring_service, "auth_token")? {
        Some(token) => Ok(token),
        None => Err("Not authenticated".to_string()),
    }
}

/// Sign out: clear keychain, optionally revoke token on the server.
#[tauri::command]
pub async fn sign_out(app: tauri::AppHandle, config: tauri::State<'_, OAuthConfig>) -> Result<(), String> {
    // Best-effort server-side revocation
    if let Some(revoke_url) = &config.revoke_endpoint {
        if let Some(token) = keychain::get(&config.keyring_service, "auth_token")? {
            let client = reqwest::Client::new();
            let _ = client
                .post(revoke_url)
                .header("Authorization", format!("Bearer {}", token))
                .send()
                .await;
        }
    }

    keychain::delete(&config.keyring_service, "auth_token")?;
    keychain::delete(&config.keyring_service, "auth_expires_at")?;

    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.delete("user");
    store.save().map_err(|e| e.to_string())?;

    Ok(())
}

/// Get the cached user from the Tauri store.
#[tauri::command]
pub fn get_user(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    let store = app.store("oauth-pkce-store.json").map_err(|e| e.to_string())?;
    store.get("user").ok_or_else(|| "User not found".to_string())
}
```

- [ ] **Step 2: Update lib.rs to register commands and manage state**

Replace the contents of `lib.rs`:

```rust
mod config;
mod pkce;
mod keychain;
mod commands;

pub use config::OAuthConfig;

use tauri::plugin::{Builder, TauriPlugin};
use tauri::{Manager, Runtime};
use tauri_plugin_store::StoreExt;

/// Initialize the OAuth PKCE plugin with the given configuration.
pub fn init<R: Runtime>(config: OAuthConfig) -> TauriPlugin<R> {
    Builder::new("oauth-pkce")
        .setup(move |app, _api| {
            // Make config available as managed state for commands
            app.manage(config.clone());

            // Clean up stale OAuth state on startup
            if let Ok(store) = app.store("oauth-pkce-store.json") {
                let stale = store
                    .get("auth_state_created_at")
                    .and_then(|v| v.as_u64())
                    .map(|created| {
                        let now = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_millis() as u64;
                        let ttl_ms = app.state::<OAuthConfig>().state_ttl_secs * 1000;
                        now.saturating_sub(created) > ttl_ms
                    })
                    .unwrap_or(false);
                if stale {
                    store.delete("auth_state");
                    store.delete("auth_code_verifier");
                    store.delete("auth_state_created_at");
                    let _ = store.save();
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::complete_auth,
            commands::check_auth_status,
            commands::get_token,
            commands::sign_out,
            commands::get_user,
        ])
        .build()
}
```

- [ ] **Step 3: Verify the crate compiles**

Run: `cd packages/tauri-plugin-oauth-pkce && cargo check`
Expected: compiles with no errors

- [ ] **Step 4: Run all tests**

Run: `cd packages/tauri-plugin-oauth-pkce && cargo test`
Expected: all PKCE tests pass (command tests require a Tauri runtime, so they won't run here — they'll be tested via integration)

- [ ] **Step 5: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/src/commands.rs packages/tauri-plugin-oauth-pkce/src/lib.rs
git commit -m "feat(tauri-plugin-oauth-pkce): implement Tauri commands and plugin init with state cleanup"
```

---

### Task 5: Scaffold JS/TS Package

**Files:**
- Create: `packages/tauri-plugin-oauth-pkce/js/package.json`
- Create: `packages/tauri-plugin-oauth-pkce/js/tsconfig.json`

- [ ] **Step 1: Create package.json**

```json
{
  "name": "tauri-plugin-oauth-pkce",
  "version": "0.1.0",
  "description": "Provider-agnostic OAuth 2.0 PKCE plugin for Tauri v2 desktop apps",
  "license": "MIT",
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "files": ["dist"],
  "scripts": {
    "build": "tsc",
    "dev": "tsc --watch"
  },
  "dependencies": {
    "@tauri-apps/api": "^2.0.0",
    "@tauri-apps/plugin-deep-link": "^2.0.0",
    "@tauri-apps/plugin-opener": "^2.0.0"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
```

- [ ] **Step 2: Create tsconfig.json**

```json
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "declaration": true,
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

- [ ] **Step 3: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/js/package.json packages/tauri-plugin-oauth-pkce/js/tsconfig.json
git commit -m "feat(tauri-plugin-oauth-pkce): scaffold JS/TS companion package"
```

---

### Task 6: Implement JS Commands Layer

**Files:**
- Create: `packages/tauri-plugin-oauth-pkce/js/src/commands.ts`

- [ ] **Step 1: Implement typed invoke wrappers**

```typescript
import { invoke } from "@tauri-apps/api/core";

export interface OAuthStateResponse {
  state: string;
  codeChallenge: string;
}

export interface AuthStatusResponse {
  status?: string;
  retryCount?: number;
  createdAt?: number;
  error?: string;
}

export interface AuthCompleteResponse {
  token: string;
  expiresAt: number;
  user: Record<string, unknown>;
}

/** Generate a fresh OAuth state + PKCE code_challenge pair. */
export async function getState(): Promise<OAuthStateResponse> {
  return invoke<OAuthStateResponse>("plugin:oauth-pkce|get_state");
}

/** Complete the OAuth flow using the state from the deep-link callback. */
export async function completeAuth(state: string): Promise<AuthCompleteResponse> {
  return invoke<AuthCompleteResponse>("plugin:oauth-pkce|complete_auth", { state });
}

/** Check the auth flow status (requires status_endpoint to be configured). */
export async function checkAuthStatus(state: string): Promise<AuthStatusResponse> {
  return invoke<AuthStatusResponse>("plugin:oauth-pkce|check_auth_status", { state });
}

/** Retrieve the auth token from the OS keychain. Throws if expired or missing. */
export async function getToken(): Promise<string> {
  return invoke<string>("plugin:oauth-pkce|get_token");
}

/** Sign out: clears keychain and optionally revokes token on the server. */
export async function signOut(): Promise<void> {
  return invoke<void>("plugin:oauth-pkce|sign_out");
}

/** Get the cached user from the Tauri store. */
export async function getUser(): Promise<Record<string, unknown>> {
  return invoke<Record<string, unknown>>("plugin:oauth-pkce|get_user");
}
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd packages/tauri-plugin-oauth-pkce/js && npx tsc --noEmit`
Expected: no type errors (may warn about missing @tauri-apps packages if not installed — that's fine at this stage)

- [ ] **Step 3: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/js/src/commands.ts
git commit -m "feat(tauri-plugin-oauth-pkce): implement typed JS command wrappers"
```

---

### Task 7: Implement OAuthClient Class

**Files:**
- Create: `packages/tauri-plugin-oauth-pkce/js/src/client.ts`

- [ ] **Step 1: Implement the OAuthClient**

```typescript
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  getState,
  completeAuth,
  checkAuthStatus,
  signOut as signOutCmd,
  getToken as getTokenCmd,
  getUser as getUserCmd,
  type AuthCompleteResponse,
} from "./commands";

const MAX_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;

export interface OAuthClientConfig {
  /** URL to open in the browser for authentication.
   * `state` and `code_challenge` will be appended as query params. */
  loginUrl: string;
}

type EventMap = {
  success: AuthCompleteResponse;
  error: { message: string; code?: string };
};

type EventHandler<K extends keyof EventMap> = (data: EventMap[K]) => void;

/**
 * Framework-agnostic OAuth client that orchestrates the full PKCE flow:
 * generates state, opens browser, listens for deep-link callback,
 * exchanges token with retry/backoff, and emits success/error events.
 */
export class OAuthClient {
  private config: OAuthClientConfig;
  private listeners: { [K in keyof EventMap]?: EventHandler<K>[] } = {};
  private pendingState: { state: string; codeChallenge: string } | null = null;
  private unlistenDeepLink: (() => void) | null = null;

  constructor(config: OAuthClientConfig) {
    this.config = config;
  }

  /** Register an event handler. */
  on<K extends keyof EventMap>(event: K, handler: EventHandler<K>): void {
    if (!this.listeners[event]) {
      this.listeners[event] = [];
    }
    this.listeners[event]!.push(handler);
  }

  /** Remove an event handler. */
  off<K extends keyof EventMap>(event: K, handler: EventHandler<K>): void {
    const list = this.listeners[event];
    if (list) {
      this.listeners[event] = list.filter((h) => h !== handler) as typeof list;
    }
  }

  private emit<K extends keyof EventMap>(event: K, data: EventMap[K]): void {
    const list = this.listeners[event];
    if (list) {
      for (const handler of list) {
        handler(data);
      }
    }
  }

  /**
   * Start the OAuth flow:
   * 1. Generate PKCE state
   * 2. Register deep-link listener
   * 3. Open browser with login URL
   */
  async startFlow(): Promise<void> {
    const result = await getState();
    this.pendingState = result;

    // Register deep-link listener before opening browser
    await this.registerDeepLinkListener();

    const separator = this.config.loginUrl.includes("?") ? "&" : "?";
    const url =
      this.config.loginUrl +
      separator +
      `state=${encodeURIComponent(result.state)}` +
      `&code_challenge=${encodeURIComponent(result.codeChallenge)}`;

    await openUrl(url);
  }

  private async registerDeepLinkListener(): Promise<void> {
    // Clean up any previous listener
    this.cleanupDeepLinkListener();

    const unlisten = await onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          this.emit("error", { message: "Malformed callback URL", code: "MALFORMED_URL" });
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) {
          this.emit("error", { message: "Missing state parameter", code: "MISSING_STATE" });
          continue;
        }

        // Validate state matches if we have a pending flow
        if (this.pendingState && callbackState !== this.pendingState.state) {
          this.emit("error", { message: "State mismatch", code: "STATE_MISMATCH" });
          continue;
        }

        await this.exchangeWithRetry(callbackState);
      }
    });

    this.unlistenDeepLink = unlisten;
  }

  private async exchangeWithRetry(state: string): Promise<void> {
    let lastError: unknown = null;

    for (let attempt = 1; attempt <= MAX_RETRIES; attempt++) {
      try {
        const result = await completeAuth(state);
        this.pendingState = null;
        this.cleanupDeepLinkListener();
        this.emit("success", result);
        return;
      } catch (error) {
        lastError = error;
        const errMsg = String(error);

        // Terminal failures — stop retrying
        if (
          errMsg.includes("already used") ||
          errMsg.includes("permanently failed") ||
          errMsg.includes("Max retries")
        ) {
          break;
        }

        if (attempt < MAX_RETRIES) {
          const is409 = errMsg.includes("409") || errMsg.includes("in progress");
          const delay = is409
            ? BASE_RETRY_DELAY_MS * 3
            : BASE_RETRY_DELAY_MS * attempt;

          // Check status if endpoint is configured
          try {
            const status = await checkAuthStatus(state);
            if (status.status === "not_found" || status.status === "completed") {
              break;
            }
          } catch {
            // Status check failed — continue with retry
          }

          await new Promise((r) => setTimeout(r, delay));
        }
      }
    }

    this.pendingState = null;
    this.cleanupDeepLinkListener();
    this.emit("error", {
      message: describeError(lastError),
      code: "AUTH_FAILED",
    });
  }

  private cleanupDeepLinkListener(): void {
    if (this.unlistenDeepLink) {
      this.unlistenDeepLink();
      this.unlistenDeepLink = null;
    }
  }

  /** Get the auth token from the OS keychain. Throws if expired or missing. */
  async getToken(): Promise<string> {
    return getTokenCmd();
  }

  /** Get the cached user from the Tauri store. */
  async getUser(): Promise<Record<string, unknown>> {
    return getUserCmd();
  }

  /** Sign out: clear keychain, optionally revoke token server-side. */
  async signOut(): Promise<void> {
    this.pendingState = null;
    this.cleanupDeepLinkListener();
    return signOutCmd();
  }
}

/** Extract a user-friendly message from an error. */
function describeError(err: unknown): string {
  if (!err) return "Unknown error";
  const raw = String(err);
  const match = raw.match(/"error"\s*:\s*"([^"]+)"/);
  if (match) return match[1];
  if (raw.includes("PKCE")) return "PKCE verification failed. Please sign in again.";
  if (raw.includes("state not found")) return "Sign-in session expired. Please try again.";
  if (raw.includes("already used")) return "This sign-in link was already used.";
  const trimmed = raw.replace(/^.*?:\s*/, "").slice(0, 200);
  return trimmed || raw.slice(0, 200);
}
```

- [ ] **Step 2: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/js/src/client.ts
git commit -m "feat(tauri-plugin-oauth-pkce): implement OAuthClient with deep-link listener and retry logic"
```

---

### Task 8: Create Index and README

**Files:**
- Create: `packages/tauri-plugin-oauth-pkce/js/src/index.ts`
- Create: `packages/tauri-plugin-oauth-pkce/README.md`

- [ ] **Step 1: Create index.ts**

```typescript
export { OAuthClient, type OAuthClientConfig } from "./client";
export {
  getState,
  completeAuth,
  checkAuthStatus,
  getToken,
  signOut,
  getUser,
  type OAuthStateResponse,
  type AuthStatusResponse,
  type AuthCompleteResponse,
} from "./commands";
```

- [ ] **Step 2: Create README.md**

```markdown
# tauri-plugin-oauth-pkce

Provider-agnostic OAuth 2.0 PKCE plugin for Tauri v2 desktop apps.

Handles the hard parts of desktop OAuth: PKCE challenge generation, deep-link callbacks, OS keychain token storage, and token exchange with retry/backoff.

## Install

**Rust side** — add to your `Cargo.toml`:
```toml
[dependencies]
tauri-plugin-oauth-pkce = { path = "../packages/tauri-plugin-oauth-pkce" }
```

**JS side** — add to your frontend:
```bash
npm install tauri-plugin-oauth-pkce
```

## Setup

### 1. Register the plugin (Rust)

```rust
use tauri_plugin_oauth_pkce::OAuthConfig;

tauri::Builder::default()
    .plugin(tauri_plugin_oauth_pkce::init(OAuthConfig {
        scheme: "myapp".into(),
        token_endpoint: "https://api.example.com/auth/complete".into(),
        status_endpoint: Some("https://api.example.com/auth/status".into()),
        revoke_endpoint: Some("https://api.example.com/auth/revoke".into()),
        keyring_service: "com.example.myapp".into(),
        state_ttl_secs: 600,
    }))
    // ... other plugins
```

### 2. Configure deep links

In your `tauri.conf.json`:
```json
{
  "plugins": {
    "deep-link": {
      "desktop": {
        "schemes": ["myapp"]
      }
    }
  }
}
```

### 3. Use in your frontend (High-Level)

```typescript
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({
  loginUrl: 'https://myapp.com/login',
});

oauth.on('success', (result) => {
  console.log('Signed in:', result.user);
  console.log('Token:', result.token);
});

oauth.on('error', (err) => {
  console.error('Auth failed:', err.message);
});

// Call this from a button click
await oauth.startFlow();

// Later
const token = await oauth.getToken();
const user = await oauth.getUser();
await oauth.signOut();
```

### 4. Use in your frontend (Low-Level)

```typescript
import { getState, completeAuth, getToken, signOut } from 'tauri-plugin-oauth-pkce';

const { state, codeChallenge } = await getState();
// Open browser manually, handle deep link manually...
const result = await completeAuth(state);
```

## Backend API Contract

Your backend must implement a token exchange endpoint. The plugin sends requests to the URLs you configure.

### Token Endpoint (required)

**POST** `token_endpoint`

Request:
```json
{ "state": "uuid-string", "code_verifier": "base64url-string" }
```

Response (200):
```json
{ "token": "jwt-string", "expiresAt": 1716043200000, "user": { ... } }
```

The `user` field can be any JSON object — it's stored as-is.

### Status Endpoint (optional)

**POST** `status_endpoint/{state}`

Request:
```json
{ "code_challenge": "hex-sha256-string" }
```

Response:
```json
{ "status": "pending" | "authenticated" | "exchanging" | "completed" }
```

### Revoke Endpoint (optional)

**POST** `revoke_endpoint`

Header: `Authorization: Bearer {token}`

Response: 200

## Provider Examples

### Clerk

Redirect users to your web app with OAuth params:
```
https://myapp.com/login?state={state}&code_challenge={code_challenge}
```

In your web app, use Clerk's `useAuth()` to get the userId after authentication, store `{ userId, codeChallenge }` in your backend (e.g., Redis keyed by state), then redirect to your deep-link scheme:
```
myapp://auth/callback?state={state}
```

### Auth0

Use Auth0's `/authorize` endpoint directly:
```
https://YOUR_DOMAIN.auth0.com/authorize
  ?response_type=code
  &client_id=YOUR_CLIENT_ID
  &redirect_uri=myapp://auth/callback
  &state={state}
  &code_challenge={code_challenge}
  &code_challenge_method=S256
```

### Supabase

```typescript
await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: `myapp://auth/callback?state=${state}` }
});
```

## Backend Examples

### Node.js / Express

```javascript
const crypto = require('crypto');
const jwt = require('jsonwebtoken');

app.post('/auth/complete', async (req, res) => {
  const { state, code_verifier } = req.body;
  const stored = await redis.get(`auth:state:${state}`);
  if (!stored) return res.status(404).json({ error: 'State not found' });

  const { codeChallenge, userId } = JSON.parse(stored);

  // PKCE verification
  const hash = crypto.createHash('sha256').update(code_verifier).digest('hex');
  if (!crypto.timingSafeEqual(Buffer.from(hash), Buffer.from(codeChallenge))) {
    return res.status(403).json({ error: 'PKCE verification failed' });
  }

  const user = await getUser(userId); // your user lookup
  const token = jwt.sign({ sub: userId }, SECRET, { expiresIn: '7d' });
  const expiresAt = Date.now() + 7 * 24 * 60 * 60 * 1000;

  await redis.del(`auth:state:${state}`);
  res.json({ token, expiresAt, user });
});
```

### Cloudflare Worker (Hono)

```typescript
app.post('/auth/complete', async (c) => {
  const { state, code_verifier } = await c.req.json();
  const stored = await c.env.KV.get(`auth:state:${state}`, 'json');
  if (!stored) return c.json({ error: 'State not found' }, 404);

  // PKCE verification (hex SHA-256)
  const hashBuf = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(code_verifier),
  );
  const challenge = [...new Uint8Array(hashBuf)]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');

  if (challenge !== stored.codeChallenge) {
    return c.json({ error: 'PKCE verification failed' }, 403);
  }

  const user = await getUser(stored.userId);
  const token = await signJwt({ sub: stored.userId }, c.env.JWT_SECRET);
  await c.env.KV.delete(`auth:state:${state}`);
  return c.json({ token, expiresAt: Date.now() + 604800000, user });
});
```

## Token Refresh

The plugin does not handle token refresh. Wrap `getToken()` with your own refresh logic:

```typescript
async function getValidToken(oauth: OAuthClient): Promise<string> {
  try {
    return await oauth.getToken();
  } catch {
    // Token expired — re-authenticate or call your refresh endpoint
    await oauth.signOut();
    await oauth.startFlow();
    throw new Error('Re-authentication required');
  }
}
```

## UI Integration Examples

### React

```tsx
function LoginButton() {
  const [signingIn, setSigningIn] = useState(false);
  const oauth = useRef(new OAuthClient({ loginUrl: '...' }));

  useEffect(() => {
    const client = oauth.current;
    client.on('success', () => setSigningIn(false));
    client.on('error', () => setSigningIn(false));
  }, []);

  return (
    <button
      onClick={() => { setSigningIn(true); oauth.current.startFlow(); }}
      disabled={signingIn}
    >
      {signingIn ? 'Signing in...' : 'Sign In'}
    </button>
  );
}
```

### Vue

```vue
<script setup>
import { ref, onMounted } from 'vue';
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({ loginUrl: '...' });
const signingIn = ref(false);

onMounted(() => {
  oauth.on('success', () => { signingIn.value = false; });
  oauth.on('error', () => { signingIn.value = false; });
});
</script>
<template>
  <button @click="signingIn = true; oauth.startFlow()" :disabled="signingIn">
    {{ signingIn ? 'Signing in...' : 'Sign In' }}
  </button>
</template>
```

### Svelte

```svelte
<script>
import { OAuthClient } from 'tauri-plugin-oauth-pkce';

const oauth = new OAuthClient({ loginUrl: '...' });
let signingIn = false;

oauth.on('success', () => { signingIn = false; });
oauth.on('error', () => { signingIn = false; });
</script>
<button on:click={() => { signingIn = true; oauth.startFlow(); }} disabled={signingIn}>
  {signingIn ? 'Signing in...' : 'Sign In'}
</button>
```

## License

MIT
```

- [ ] **Step 3: Verify TS compiles**

Run: `cd packages/tauri-plugin-oauth-pkce/js && npm install && npx tsc --noEmit`
Expected: no type errors

- [ ] **Step 4: Commit**

```bash
git add packages/tauri-plugin-oauth-pkce/js/src/index.ts packages/tauri-plugin-oauth-pkce/README.md
git commit -m "feat(tauri-plugin-oauth-pkce): add index re-exports and README with provider/backend examples"
```
