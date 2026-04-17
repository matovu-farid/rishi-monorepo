import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getState, logAuthDebugCmd } from "@/generated";

/**
 * Retrieve the auth token from the OS keychain via a Tauri command.
 * Expiry is checked on the Rust side — this throws if expired or missing.
 */
export async function getAuthToken(): Promise<string> {
  return await invoke<string>("get_auth_token_cmd");
}

/**
 * Module-level cache for the in-flight OAuth state (state + PKCE
 * code_challenge), shared between startSignInFlow (which sets it before
 * opening the auth URL) and useHydrateAuth's deep-link listener (which
 * validates the callback against it).
 *
 * Without this cache, the URL state and the validation state would diverge
 * because they live in different modules with no link between them.
 */
let pendingOAuthState: { state: string; codeChallenge: string } | null = null;

/**
 * Returns the OAuth state currently expected for callback validation, or
 * generates a fresh one (cold-start path: app opened via deep link with no
 * prior in-flight flow). The result is always cached for the next caller.
 */
export async function ensureOAuthState(): Promise<{ state: string; codeChallenge: string }> {
  if (pendingOAuthState) return pendingOAuthState;
  const fresh = await getState();
  pendingOAuthState = fresh;
  return fresh;
}

/**
 * Read-only accessor: returns the in-flight OAuth state if one exists, or
 * `null` without side effects. Use this from the callback path so we never
 * rotate the persisted `auth_code_verifier` while trying to validate an
 * incoming callback — rotating would break PKCE for the state the server
 * is actually expecting.
 */
export function peekPendingOAuthState(): { state: string; codeChallenge: string } | null {
  return pendingOAuthState;
}

/** Reset the cache (called after a successful or terminal-failed auth round-trip). */
export function clearPendingOAuthState(): void {
  pendingOAuthState = null;
}

/**
 * Open the Rishi sign-in URL in the user's default browser. Generates a fresh
 * OAuth state + code_challenge for each call and caches it so the deep-link
 * callback listener can validate against the same value.
 *
 * Errors are logged but not thrown — callers may invoke this from passive UI
 * (banner, modal) where surfacing a failure is worse than silently failing.
 *
 * The OAuth callback is handled by the deep-link listener in useHydrateAuth().
 */
export async function startSignInFlow(): Promise<void> {
  try {
    const result = await getState();
    pendingOAuthState = result;
    const url =
      `https://rishi.fidexa.org?login=true` +
      `&state=${encodeURIComponent(result.state)}` +
      `&code_challenge=${encodeURIComponent(result.codeChallenge)}`;
    // Log the sign-in flow initiation with state for tracing
    void logAuthDebugCmd({
      state: result.state,
      step: "sign_in_flow_started",
      data: JSON.stringify({ challengeLen: result.codeChallenge.length, url: url.slice(0, 120) }),
    }).catch(() => {});
    await openUrl(url);
  } catch (err) {
    console.error("[auth] failed to start sign-in flow:", err);
  }
}
