import { create } from "zustand";
import { devtools } from "zustand/middleware";
import type { User } from "@/generated";

const WELCOME_SEEN_KEY = "rishi:welcome-seen";

interface AuthState {
  user: User | null;
  signingIn: boolean;
  authHydrated: boolean;
  welcomeSeen: boolean;
  bannerDismissed: boolean;
  devMode: boolean;

  // Actions
  setUser: (user: User | null) => void;
  setSigningIn: (value: boolean) => void;
  setDevMode: (value: boolean) => void;
  hydrateAuth: () => void;
  dismissBanner: () => void;
  dismissWelcome: () => void;
  setWelcomeSeen: () => void;
  setAuthHydrated: (value: boolean) => void;
}

export const useAuthStore = create<AuthState>()(
  devtools(
    (set) => ({
      user: null,
      signingIn: false,
      authHydrated: false,
      welcomeSeen: false,
      bannerDismissed: false,
      devMode: false,

      setUser: (user) => set({ user }),
      setSigningIn: (value) => set({ signingIn: value }),
      setDevMode: (value) => set({ devMode: value }),
      setAuthHydrated: (value) => set({ authHydrated: value }),

      hydrateAuth: () => {
        try {
          const value = localStorage.getItem(WELCOME_SEEN_KEY);
          set({ welcomeSeen: value === "1" });
        } catch (err) {
          console.warn("[authStore] failed to read welcome-seen flag, fail-closing:", err);
          set({ welcomeSeen: true });
        }
      },

      dismissBanner: () => set({ bannerDismissed: true }),

      dismissWelcome: () => {
        set({ welcomeSeen: true, bannerDismissed: true });
        try {
          localStorage.setItem(WELCOME_SEEN_KEY, "1");
        } catch (err) {
          console.warn("[authStore] failed to persist welcome-seen flag:", err);
        }
      },

      setWelcomeSeen: () => {
        set({ welcomeSeen: true });
        try {
          localStorage.setItem(WELCOME_SEEN_KEY, "1");
        } catch (err) {
          console.warn("[authStore] failed to persist welcome-seen flag:", err);
        }
      },
    }),
    { name: "auth-store" }
  )
);
