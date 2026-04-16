import { useAtomValue, useSetAtom } from "jotai";
import { Sparkles, X, LogIn } from "lucide-react";
import { Button } from "@components/components/ui/button";
import {
  showSignInBannerAtom,
  dismissBannerAtom,
} from "@/atoms/authPromo";
import { startSignInFlow } from "@/modules/auth";

/**
 * Persistent bottom-left card prompting unauthenticated returning users to
 * sign in. Mounted once at the root; positions itself just above the existing
 * SyncStatusIndicator.
 */
export function SignInBanner(): React.JSX.Element | null {
  const visible = useAtomValue(showSignInBannerAtom);
  const dismiss = useSetAtom(dismissBannerAtom);

  if (!visible) return null;

  return (
    <div
      className="fixed bottom-16 left-4 z-50 flex w-72 items-center gap-3 rounded-lg border bg-background/95 p-3 shadow-md backdrop-blur"
      role="region"
      aria-label="Sign-in promotion"
    >
      <div className="rounded-full bg-primary/10 p-2 shrink-0">
        <Sparkles size={16} className="text-primary" />
      </div>
      <div className="min-w-0 flex-1 text-sm">
        <p className="font-medium leading-tight">Unlock AI features</p>
        <p className="text-xs text-muted-foreground leading-tight">
          Sign in for TTS, chat, and sync.
        </p>
      </div>
      <Button
        size="sm"
        onClick={() => {
          void startSignInFlow();
        }}
      >
        <LogIn size={14} className="mr-1" />
        Sign in
      </Button>
      <button
        type="button"
        onClick={() => dismiss()}
        aria-label="Dismiss sign-in banner"
        className="absolute right-1 top-1 rounded p-1 text-muted-foreground hover:bg-muted"
      >
        <X size={12} />
      </button>
    </div>
  );
}
