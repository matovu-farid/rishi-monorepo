import { invoke } from "@tauri-apps/api/core";

/**
 * Retrieve the auth token from the OS keychain via a Tauri command.
 * Expiry is checked on the Rust side — this throws if expired or missing.
 */
export async function getAuthToken(): Promise<string> {
  return await invoke<string>("get_auth_token_cmd");
}
