import { atom } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";

export const WELCOME_SEEN_KEY = "rishi:welcome-seen";

// --- Primitive atoms ---

/** True while the sign-in flow is in progress (browser opened → auth completes/fails). */
export const signingInAtom = atom(false);

/** True once the initial getUserFromStore() resolves (success or failure). */
export const authHydratedAtom = atom(false);

/** True once the welcome modal has been shown+closed. Hydrated from localStorage. */
export const welcomeSeenAtom = atom(false);

/** Session-only: banner dismissed for the current run. Resets on cold start. */
export const bannerDismissedAtom = atom(false);

// --- Derived visibility atoms ---

export const showWelcomeModalAtom = atom((get) =>
  get(authHydratedAtom) && !get(isLoggedInAtom) && !get(welcomeSeenAtom),
);

export const showSignInBannerAtom = atom((get) =>
  get(authHydratedAtom) &&
  !get(isLoggedInAtom) &&
  get(welcomeSeenAtom) &&
  !get(bannerDismissedAtom),
);

// --- Write-path atoms (each is a write-only atom for clean side effects) ---

/** Mark welcome-seen: updates atom AND writes localStorage. Fail-closed on storage errors. */
export const setWelcomeSeenAtom = atom(null, (_get, set) => {
  set(welcomeSeenAtom, true);
  try {
    localStorage.setItem(WELCOME_SEEN_KEY, "1");
  } catch (err) {
    console.warn("[authPromo] failed to persist welcome-seen flag:", err);
  }
});

/** Dismiss banner for current session only (no localStorage write). */
export const dismissBannerAtom = atom(null, (_get, set) => {
  set(bannerDismissedAtom, true);
});

/**
 * "Maybe later" on welcome modal: persist welcome-seen AND suppress banner
 * for the current session (so the user isn't immediately re-prompted).
 */
export const dismissWelcomeAtom = atom(null, (_get, set) => {
  set(setWelcomeSeenAtom);
  set(bannerDismissedAtom, true);
});

/**
 * Read localStorage on app boot and seed welcomeSeenAtom.
 * Fail-closed: on any read error, treat welcomeSeen=true to avoid showing the
 * modal repeatedly to a user whose state we can't persist.
 */
export const hydrateWelcomeSeenAtom = atom(null, (_get, set) => {
  try {
    const value = localStorage.getItem(WELCOME_SEEN_KEY);
    set(welcomeSeenAtom, value === "1");
  } catch (err) {
    console.warn("[authPromo] failed to read welcome-seen flag, fail-closing:", err);
    set(welcomeSeenAtom, true);
  }
});
