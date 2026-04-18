import { useCallback, useState } from "react";
import { useAtomValue } from "jotai";
import { isLoggedInAtom } from "@/components/pdf/atoms/user";
import { PremiumFeatureDialog } from "@/components/auth/PremiumFeatureDialog";
import type { PremiumFeature } from "@/components/auth/features";
import { devModeAtom } from "@/atoms/authPromo";

/**
 * Gates premium (auth-required) features behind sign-in.
 * In dev mode (tauri::is_dev), the auth gate is bypassed — all features are accessible.
 *
 * Usage:
 *   const { requireAuth, AuthDialog } = useRequireAuth();
 *   <button onClick={() => requireAuth("tts", () => player.play())}>Play</button>
 *   {AuthDialog}
 */
export function useRequireAuth() {
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const isDevMode = useAtomValue(devModeAtom);
  const [open, setOpen] = useState(false);
  const [feature, setFeature] = useState<PremiumFeature>("ai-generic");

  const requireAuth = useCallback(
    (f: PremiumFeature, action: () => void) => {
      if (isLoggedIn || isDevMode) {
        action();
      } else {
        setFeature(f);
        setOpen(true);
      }
    },
    [isLoggedIn, isDevMode],
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
