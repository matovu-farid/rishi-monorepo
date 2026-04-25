import { useCallback, useState } from "react";
import { useAuthStore } from "@/stores/authStore";
import { PremiumFeatureDialog } from "@/components/auth/PremiumFeatureDialog";
import type { PremiumFeature } from "@/components/auth/features";

/**
 * Gates premium (auth-required) features behind sign-in.
 *
 * The dialog always shows when the user is not authenticated, even in dev mode.
 * Dev-mode bypass for premium API calls is handled separately at the network
 * layer via the X-Dev-Bypass header + DEV_BYPASS_SECRET env var.
 *
 * Usage:
 *   const { requireAuth, AuthDialog } = useRequireAuth();
 *   <button onClick={() => requireAuth("tts", () => player.play())}>Play</button>
 *   {AuthDialog}
 */
export function useRequireAuth() {
  const isLoggedIn = useAuthStore((s) => s.user !== null);
  const [open, setOpen] = useState(false);
  const [feature, setFeature] = useState<PremiumFeature>("ai-generic");

  const requireAuth = useCallback(
    (f: PremiumFeature, action: () => void) => {
      if (isLoggedIn) {
        action();
      } else {
        setFeature(f);
        setOpen(true);
      }
    },
    [isLoggedIn],
  );

  const AuthDialog = (
    <PremiumFeatureDialog
      open={open}
      onOpenChange={setOpen}
      feature={feature}
    />
  );

  return { requireAuth, AuthDialog };
}
