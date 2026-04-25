/**
 * Auth module — deep-link PKCE flow (ported from the Tauri app).
 *
 * Sign-in opens the system browser where the user already has saved sessions
 * for Google, GitHub, etc. The browser authenticates via Clerk on the web app,
 * then deep-links back to the Electron app with a state parameter. The main
 * process completes the PKCE exchange with the worker API and returns a JWT.
 */

import { useAuthStore } from "@/stores/authStore";

// ── Token helpers ────────────────────────────────────────────────────

export async function getAuthToken(): Promise<string | null> {
  return window.electron.getAuthToken();
}

export async function saveAuthToken(token: string, expiresAt: number): Promise<void> {
  return window.electron.saveAuthToken(token, expiresAt);
}

export async function clearAuth(): Promise<void> {
  return window.electron.clearAuth();
}

export async function getUserFromStore() {
  return window.electron.getUserFromStore();
}

export async function saveUserToStore(user: any) {
  return window.electron.saveUserToStore(user);
}

// ── PKCE state cache ─────────────────────────────────────────────────

let pendingOAuthState: { state: string; codeChallenge: string } | null = null;

/**
 * Returns the cached OAuth state, or generates a fresh one from the main
 * process (which persists the code_verifier for later PKCE verification).
 */
export async function ensureOAuthState(): Promise<{ state: string; codeChallenge: string }> {
  if (pendingOAuthState) return pendingOAuthState;
  const fresh = await window.electron.getOAuthState();
  pendingOAuthState = fresh;
  return fresh;
}

/** Read-only peek — returns the cached state without side effects. */
export function peekPendingOAuthState(): { state: string; codeChallenge: string } | null {
  return pendingOAuthState;
}

/** Reset the cache after a completed or terminally-failed auth round-trip. */
export function clearPendingOAuthState(): void {
  pendingOAuthState = null;
}

// ── Sign-in flow ─────────────────────────────────────────────────────

/**
 * Open the system browser to the Rishi web app for Clerk authentication.
 * The web app will deep-link back to rishi-electron://auth/callback after
 * successful login.
 */
export async function startSignInFlow(): Promise<void> {
  try {
    // IMPORTANT: set pendingOAuthState BEFORE setSigningIn, because
    // setSigningIn triggers a React re-render that fires the polling
    // effect. If pendingOAuthState is null when the effect runs, polling
    // won't start and sign-in gets stuck in a loading state forever.
    const result = await window.electron.getOAuthState();
    pendingOAuthState = result;
    useAuthStore.getState().setSigningIn(true);
    const url =
      `https://rishi.fidexa.org?login=true` +
      `&state=${encodeURIComponent(result.state)}` +
      `&code_challenge=${encodeURIComponent(result.codeChallenge)}` +
      `&redirect_scheme=rishi-electron`;
    await window.electron.openExternal(url);
  } catch (err) {
    useAuthStore.getState().setSigningIn(false);
    console.error("[auth] failed to start sign-in flow:", err);
  }
}
