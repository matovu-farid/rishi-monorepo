import { useUser, SignedIn, UserButton } from "@clerk/clerk-react";
import { useEffect } from "react";
import { useAuthStore } from "@/stores/authStore";
import { saveUserToStore } from "@/modules/auth";

const CLERK_KEY = import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || "";

// ── Clerk → Zustand sync ────────────────────────────────────────────

/**
 * Keeps the Zustand auth store in sync with Clerk's session state.
 * If the user signs in via Clerk (email/password in-app), this maps the
 * Clerk user to our local User shape and persists it. If no Clerk key is
 * configured, it no-ops (deep-link auth handles hydration via useHydrateAuth).
 */
export function ClerkAuthSync() {
  if (!CLERK_KEY) return null;
  return <ClerkAuthSyncInner />;
}

function ClerkAuthSyncInner() {
  const { user, isLoaded } = useUser();
  const setUser = useAuthStore((s) => s.setUser);
  const existingUser = useAuthStore((s) => s.user);

  useEffect(() => {
    if (!isLoaded) return;

    if (user) {
      const mapped = {
        id: user.id,
        firstName: user.firstName,
        lastName: user.lastName,
        fullName: user.fullName,
        username: user.username,
        imageUrl: user.imageUrl,
        hasImage: user.hasImage,
        lastSignInAt: user.lastSignInAt?.getTime() ?? null,
        externalId: user.externalId,
      };
      setUser(mapped);
      void saveUserToStore(mapped);
    } else if (!existingUser) {
      // Only clear if we don't already have a deep-link-authenticated user
      setUser(null);
    }
  }, [user, isLoaded, setUser, existingUser]);

  return null;
}

// ── Clerk user button (used when Clerk session exists) ───────────────

export function ClerkUserButton() {
  if (!CLERK_KEY) return null;
  return (
    <SignedIn>
      <UserButton />
    </SignedIn>
  );
}
