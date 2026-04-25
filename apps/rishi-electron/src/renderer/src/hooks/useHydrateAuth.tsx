import { useEffect, useRef } from "react";
import { toast } from "react-toastify";
import { useAuthStore } from "@/stores/authStore";
import { peekPendingOAuthState, clearPendingOAuthState } from "@/modules/auth";

const MAX_AUTH_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 1500;
const POLL_INTERVAL_MS = 2000;
const POLL_TIMEOUT_MS = 5 * 60 * 1000; // stop polling after 5 minutes

/**
 * Root-level hook: runs exactly once on app mount.
 *
 * 1. Hydrates `welcomeSeen` from localStorage.
 * 2. Loads the user from secure storage into authStore; sets
 *    `authHydrated = true` so promo UI can decide what to show.
 * 3. Registers the deep-link callback listener for OAuth with retry/backoff.
 * 4. Polls the worker status endpoint as a fallback when deep links don't work.
 *    Whichever path completes first (deep link or poll) wins.
 */
export function useHydrateAuth(): void {
  const setUser = useAuthStore((s) => s.setUser);
  const setAuthHydrated = useAuthStore((s) => s.setAuthHydrated);
  const hydrateWelcomeSeen = useAuthStore((s) => s.hydrateAuth);
  const setSigningIn = useAuthStore((s) => s.setSigningIn);
  const setDevMode = useAuthStore((s) => s.setDevMode);

  // Shared flag so deep-link and polling don't race
  const authCompleted = useRef(false);

  // ── 1 + 2: hydrate localStorage flags + stored user ──────────────
  useEffect(() => {
    hydrateWelcomeSeen();

    void (async () => {
      try {
        const dev = await window.electron.isDev();
        setDevMode(dev);
      } catch {
        /* ignore */
      }
      try {
        const user = await window.electron.getUserFromStore();
        setUser(user);
      } catch (err) {
        setUser(null);
        console.error("[useHydrateAuth] failed to load user from store:", err);
      } finally {
        setAuthHydrated(true);
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── 3: deep-link OAuth callback listener ──────────────────────────
  useEffect(() => {
    let cancelled = false;

    const unlisten = window.electron.onDeepLink(async (url) => {
      if (cancelled || authCompleted.current) return;
      if (!url.includes("auth/callback")) return;

      let params: URLSearchParams;
      try {
        params = new URL(url).searchParams;
      } catch {
        console.error("[useHydrateAuth] malformed deep link URL:", url);
        toast.error("Sign-in failed: malformed callback URL");
        return;
      }

      const callbackState = params.get("state");
      if (!callbackState) {
        toast.error("Sign-in failed: missing state parameter");
        return;
      }

      const expected = peekPendingOAuthState();
      if (expected && callbackState !== expected.state) {
        console.error("[useHydrateAuth] auth callback state mismatch");
        toast.error("Sign-in failed: state mismatch. Please try signing in again.");
        return;
      }

      await attemptCompleteAuth(callbackState);
    });

    return () => {
      cancelled = true;
      unlisten();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ── 4: polling fallback ───────────────────────────────────────────
  // When signingIn becomes true, poll the worker every 3s to detect when
  // the user has authenticated in the browser. This works even when deep
  // links fail (Linux, dev mode, unregistered protocol).
  const signingIn = useAuthStore((s) => s.signingIn);

  useEffect(() => {
    if (!signingIn || authCompleted.current) return;

    const pending = peekPendingOAuthState();
    if (!pending) return;

    const startedAt = Date.now();
    let stopped = false;

    const poll = async () => {
      while (!stopped && !authCompleted.current) {
        // Timeout after 5 minutes
        if (Date.now() - startedAt > POLL_TIMEOUT_MS) {
          console.log("[useHydrateAuth] polling timed out");
          setSigningIn(false);
          return;
        }

        try {
          const status = await window.electron.checkAuthStatus(pending.state);
          console.log("[useHydrateAuth] poll status:", status.status);

          if (status.status === "authenticated") {
            // User authenticated in browser — complete the exchange
            await attemptCompleteAuth(pending.state);
            return;
          }

          if (status.status === "completed" || status.status === "failed") {
            // Already completed or permanently failed
            clearPendingOAuthState();
            setSigningIn(false);
            return;
          }
        } catch {
          // Status check failed (network, no state yet) — keep polling
        }

        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
      }
    };

    void poll();

    return () => {
      stopped = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [signingIn]);

  // ── Shared auth completion logic ──────────────────────────────────
  async function attemptCompleteAuth(state: string): Promise<void> {
    if (authCompleted.current) return;

    let lastError: unknown = null;
    for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
      if (authCompleted.current) return;
      try {
        const user = await window.electron.completeAuth(state);
        authCompleted.current = true;
        setUser(user);
        setSigningIn(false);
        clearPendingOAuthState();
        const greeting =
          user && typeof user === "object" && "firstName" in user && user.firstName
            ? `Signed in as ${user.firstName}`
            : "Signed in successfully";
        toast.success(greeting);
        return;
      } catch (error) {
        lastError = error;
        const errMsg = String(error);
        console.error(
          `[useHydrateAuth] auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`,
          error
        );

        if (
          errMsg.includes("already used") ||
          errMsg.includes("permanently failed") ||
          errMsg.includes("Max retries")
        ) {
          setSigningIn(false);
          clearPendingOAuthState();
          return;
        }

        if (attempt < MAX_AUTH_RETRIES) {
          const is409 = errMsg.includes("409") || errMsg.includes("in progress");
          const delay = is409
            ? BASE_RETRY_DELAY_MS * 3
            : BASE_RETRY_DELAY_MS * attempt;

          try {
            const status = await window.electron.checkAuthStatus(state);
            if (status.status === "not_found" || status.status === "completed") {
              clearPendingOAuthState();
              return;
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
    toast.error(`Sign-in failed: ${describeAuthError(lastError)}`);
  }
}

function describeAuthError(err: unknown): string {
  if (!err) return "unknown error";
  const raw = String(err);
  const match = raw.match(/"error"\s*:\s*"([^"]+)"/);
  if (match) return match[1];
  if (raw.includes("PKCE")) return "PKCE verification failed. Please sign in again.";
  if (raw.includes("state not found")) return "Sign-in session expired. Please try again.";
  if (raw.includes("already used")) return "This sign-in link was already used.";
  const trimmed = raw.replace(/^.*?:\s*/, "").slice(0, 200);
  return trimmed || raw.slice(0, 200);
}
