import { useEffect } from "react";
import { useSetAtom } from "jotai";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { toast } from "react-toastify";
import {
  getUserFromStore,
  completeAuth,
  checkAuthStatus,
  logAuthDebugCmd,
} from "@/generated";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  hydrateWelcomeSeenAtom,
  signingInAtom,
} from "@/atoms/authPromo";
import { peekPendingOAuthState, clearPendingOAuthState } from "@/modules/auth";

/** Best-effort debug log to Redis via the Rust command. Never throws. */
async function debugLog(state: string, step: string, data?: unknown, error?: string) {
  try {
    await logAuthDebugCmd({ state, step, data: data != null ? JSON.stringify(data) : undefined, error: error ?? undefined });
  } catch {
    // swallow — must never block auth flow
  }
}

const MAX_AUTH_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;

/**
 * Root-level hook: runs exactly once on app mount.
 *
 * 1. Hydrates `welcomeSeenAtom` from localStorage.
 * 2. Loads the user from the OS keychain into `userAtom`; sets
 *    `authHydratedAtom = true` in `finally` so promo UI can decide what to show.
 * 3. Registers the OAuth deep-link callback listener with retry/backoff
 *    matching the previous logic in LoginButton.tsx.
 *
 * The OAuth state used for callback validation is shared with `startSignInFlow`
 * via the module-level cache in `@/modules/auth`.
 */
export function useHydrateAuth(): void {
  const setUser = useSetAtom(userAtom);
  const setAuthHydrated = useSetAtom(authHydratedAtom);
  const hydrateWelcomeSeen = useSetAtom(hydrateWelcomeSeenAtom);
  const setSigningIn = useSetAtom(signingInAtom);

  // 1 + 2: hydrate localStorage + keychain user.
  useEffect(() => {
    hydrateWelcomeSeen();

    void (async () => {
      try {
        const user = await getUserFromStore();
        setUser(user);
      } catch (err) {
        setUser(null);
        console.error("[useHydrateAuth] failed to load user from store:", err);
      } finally {
        setAuthHydrated(true);
      }
    })();
    // run-once on mount
  }, []);

  // 3: deep-link OAuth callback listener.
  useEffect(() => {
    const unlisten = onOpenUrl(async (urls) => {
      void debugLog("global", "onOpenUrl_fired", { urlCount: urls.length, urls: urls.map(u => u.slice(0, 100)) });

      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          console.error("[useHydrateAuth] malformed deep link URL:", url);
          void debugLog("unknown", "deeplink_malformed_url", { url: url.slice(0, 200) });
          toast.error("Sign-in failed: malformed callback URL");
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) {
          void debugLog("unknown", "deeplink_missing_state", { url: url.slice(0, 200) });
          toast.error("Sign-in failed: missing state parameter");
          continue;
        }

        void debugLog(callbackState, "deeplink_received", { url: url.slice(0, 200) });

        // Read-only peek: if a pending flow exists, validate the callback
        // matches it. If no pending flow exists (app restart between login
        // click and callback, or dev HMR wipe), skip client-side validation
        // — the server-side PKCE check in /api/auth/complete is authoritative.
        const expected = peekPendingOAuthState();
        void debugLog(callbackState, "deeplink_state_check", {
          hasPendingState: !!expected,
          pendingStateMatch: expected ? callbackState === expected.state : "n/a",
        });

        if (expected && callbackState !== expected.state) {
          console.error(
            "[useHydrateAuth] auth callback state mismatch — ignoring",
            { callbackState, expectedState: expected.state },
          );
          void debugLog(callbackState, "deeplink_state_mismatch", {
            expectedState: expected.state.slice(0, 8) + "...",
          });
          toast.error("Sign-in failed: state mismatch. Please try signing in again.");
          continue;
        }

        let lastError: unknown = null;
        for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
          try {
            void debugLog(callbackState, "complete_auth_attempt", { attempt, maxRetries: MAX_AUTH_RETRIES });
            const user = await completeAuth({ state: callbackState });
            void debugLog(callbackState, "complete_auth_success_ts", { userId: user.id, attempt });
            setUser(user);
            setSigningIn(false);
            clearPendingOAuthState();
            const greeting = user.firstName
              ? `Signed in as ${user.firstName}`
              : "Signed in successfully";
            toast.success(greeting);
            return;
          } catch (error) {
            lastError = error;
            const errMsg = String(error);
            console.error(
              `[useHydrateAuth] auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`,
              error,
            );
            void debugLog(callbackState, "complete_auth_attempt_failed", { attempt }, errMsg);

            if (
              errMsg.includes("already used") ||
              errMsg.includes("permanently failed") ||
              errMsg.includes("Max retries")
            ) {
              void debugLog(callbackState, "complete_auth_terminal_failure", { attempt }, errMsg);
              setSigningIn(false);
              clearPendingOAuthState();
              break;
            }

            if (attempt < MAX_AUTH_RETRIES) {
              const is409 = errMsg.includes("409") || errMsg.includes("in progress");
              const delay = is409
                ? BASE_RETRY_DELAY_MS * 3
                : BASE_RETRY_DELAY_MS * attempt;

              try {
                const status = await checkAuthStatus({ state: callbackState });
                console.log("[useHydrateAuth] auth flow status:", status);
                void debugLog(callbackState, "auth_status_check", status);
                if (status.status === "not_found" || status.status === "completed") {
                  clearPendingOAuthState();
                  break;
                }
              } catch {
                // fall through and retry
              }

              await new Promise((r) => setTimeout(r, delay));
            }
          }
        }
        console.error("[useHydrateAuth] all auth attempts failed");
        setSigningIn(false);
        void debugLog(callbackState, "all_auth_attempts_failed", null, describeAuthError(lastError));
        toast.error(`Sign-in failed: ${describeAuthError(lastError)}`);
      }
    });

    return () => {
      void unlisten.then((fn) => fn());
    };
    // run-once on mount
  }, []);
}

/**
 * Extract a user-friendly message from the Tauri/worker error string.
 * The Rust side returns errors as plain strings (e.g. "Auth completion
 * failed (403): {\"error\":\"PKCE verification failed\"}"); surface the
 * most actionable part without exposing stack traces.
 */
function describeAuthError(err: unknown): string {
  if (!err) return "unknown error";
  const raw = String(err);
  // Try to pull a JSON {"error":"..."} body out of the Rust-formatted string.
  const match = raw.match(/"error"\s*:\s*"([^"]+)"/);
  if (match) return match[1];
  if (raw.includes("PKCE")) return "PKCE verification failed. Please sign in again.";
  if (raw.includes("state not found")) return "Sign-in session expired. Please try again.";
  if (raw.includes("already used")) return "This sign-in link was already used.";
  // Strip long prefixes like "Auth completion failed (500): "
  const trimmed = raw.replace(/^.*?:\s*/, "").slice(0, 200);
  return trimmed || raw.slice(0, 200);
}
