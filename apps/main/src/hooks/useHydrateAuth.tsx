import { useEffect, useRef } from "react";
import { useSetAtom } from "jotai";
import { onOpenUrl } from "@tauri-apps/plugin-deep-link";
import {
  getUserFromStore,
  getState,
  completeAuth,
  checkAuthStatus,
} from "@/generated";
import { userAtom } from "@/components/pdf/atoms/user";
import {
  authHydratedAtom,
  hydrateWelcomeSeenAtom,
} from "@/atoms/authPromo";

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
 */
export function useHydrateAuth(): void {
  const setUser = useSetAtom(userAtom);
  const setAuthHydrated = useSetAtom(authHydratedAtom);
  const hydrateWelcomeSeen = useSetAtom(hydrateWelcomeSeenAtom);

  // Lazy state for OAuth — generated when needed (login click or callback).
  const stateRef = useRef<string | null>(null);
  const codeChallengeRef = useRef<string | null>(null);

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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 3: deep-link OAuth callback listener.
  useEffect(() => {
    async function ensureState() {
      if (!stateRef.current || !codeChallengeRef.current) {
        const result = await getState();
        stateRef.current = result.state;
        codeChallengeRef.current = result.codeChallenge;
      }
    }

    const unlisten = onOpenUrl(async (urls) => {
      for (const url of urls) {
        if (!url.includes("auth/callback")) continue;

        let params: URLSearchParams;
        try {
          params = new URL(url).searchParams;
        } catch {
          console.error("[useHydrateAuth] malformed deep link URL:", url);
          continue;
        }

        const callbackState = params.get("state");
        if (!callbackState) continue;

        await ensureState();

        if (callbackState !== stateRef.current) {
          console.error("[useHydrateAuth] auth callback state mismatch — ignoring");
          continue;
        }

        for (let attempt = 1; attempt <= MAX_AUTH_RETRIES; attempt++) {
          try {
            const user = await completeAuth({ state: callbackState });
            setUser(user);
            const fresh = await getState();
            stateRef.current = fresh.state;
            codeChallengeRef.current = fresh.codeChallenge;
            return;
          } catch (error) {
            const errMsg = String(error);
            console.error(
              `[useHydrateAuth] auth attempt ${attempt}/${MAX_AUTH_RETRIES} failed:`,
              error,
            );

            if (
              errMsg.includes("already used") ||
              errMsg.includes("permanently failed") ||
              errMsg.includes("Max retries")
            ) {
              break;
            }

            if (attempt < MAX_AUTH_RETRIES) {
              const is409 = errMsg.includes("409") || errMsg.includes("in progress");
              const delay = is409
                ? BASE_RETRY_DELAY_MS * 3
                : BASE_RETRY_DELAY_MS * attempt;

              try {
                const status = await checkAuthStatus({ state: callbackState });
                if (status.status === "not_found" || status.status === "completed") {
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
      }
    });

    return () => {
      void unlisten.then((fn) => fn());
    };
    // run-once on mount
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
