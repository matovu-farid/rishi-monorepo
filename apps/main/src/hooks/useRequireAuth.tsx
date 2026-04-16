import { useCallback, useState } from "react";
import { useAtomValue } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";
import { PremiumFeatureDialog } from "@/components/auth/PremiumFeatureDialog";
import type { PremiumFeature } from "@/components/auth/features";

/**
 * Gates premium (auth-required) features behind sign-in.
 *
 * Usage:
 *   const { requireAuth, AuthDialog } = useRequireAuth();
 *   <button onClick={() => requireAuth("tts", () => player.play())}>Play</button>
 *   {AuthDialog}
 */
export function useRequireAuth() {
  const isLoggedIn = useAtomValue(isLoggedInAtom);
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
