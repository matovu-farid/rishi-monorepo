import { Sparkles, X, LogIn, Loader2 } from "lucide-react";
import { useAuthStore } from "@/stores/authStore";
import { startSignInFlow } from "@/modules/auth";

/**
 * Persistent bottom-left card prompting unauthenticated returning users to
 * sign in via the system browser (deep-link flow).
 */
export function SignInBanner(): React.JSX.Element | null {
  const visible = useAuthStore(
    (s) => s.authHydrated && s.user === null && s.welcomeSeen && !s.bannerDismissed
  );
  const dismiss = useAuthStore((s) => s.dismissBanner);
  const signingIn = useAuthStore((s) => s.signingIn);

  if (!visible) return null;

  return (
    <div
      className="fixed bottom-16 left-4 z-50 flex w-72 items-center gap-3 rounded-lg border border-gray-200 bg-white/95 p-3 shadow-md backdrop-blur"
      role="region"
      aria-label="Sign-in promotion"
    >
      <div className="rounded-full bg-gray-100 p-2 shrink-0">
        <Sparkles size={16} className="text-gray-900" />
      </div>
      <div className="min-w-0 flex-1 text-sm">
        <p className="font-medium leading-tight">Unlock AI features</p>
        <p className="text-xs text-gray-500 leading-tight">
          Sign in for TTS, chat, and sync.
        </p>
      </div>
      <button
        className="inline-flex items-center gap-1 rounded-lg bg-gray-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-gray-800 disabled:opacity-50"
        disabled={signingIn}
        onClick={() => startSignInFlow()}
      >
        {signingIn ? (
          <Loader2 size={14} className="animate-spin" />
        ) : (
          <LogIn size={14} />
        )}
        Sign in
      </button>
      <button
        type="button"
        onClick={() => dismiss()}
        aria-label="Dismiss sign-in banner"
        className="absolute right-1 top-1 rounded p-1 text-gray-400 hover:bg-gray-100"
      >
        <X size={12} />
      </button>
    </div>
  );
}
