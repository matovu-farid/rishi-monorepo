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
