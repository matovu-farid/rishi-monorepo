import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getState } from "@/generated";

/**
 * Retrieve the auth token from the OS keychain via a Tauri command.
 * Expiry is checked on the Rust side — this throws if expired or missing.
 */
export async function getAuthToken(): Promise<string> {
  return await invoke<string>("get_auth_token_cmd");
}

/**
 * Open the Rishi sign-in URL in the user's default browser. Generates a fresh
 * OAuth state + code_challenge for each call. Errors are logged but not
 * thrown — callers may invoke this from passive UI (banner, modal) where
 * surfacing a failure is worse than silently failing.
 *
 * The OAuth callback is handled by the deep-link listener in useHydrateAuth().
 */
export async function startSignInFlow(): Promise<void> {
  try {
    const { state, codeChallenge } = await getState();
    await openUrl(
      `https://rishi.fidexa.org?login=true` +
        `&state=${encodeURIComponent(state)}` +
        `&code_challenge=${encodeURIComponent(codeChallenge)}`,
    );
  } catch (err) {
    console.error("[auth] failed to start sign-in flow:", err);
  }
}
