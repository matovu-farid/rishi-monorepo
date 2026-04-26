import { LogIn, Check, Loader2 } from 'lucide-react'
import { useAuthStore } from '@/stores/authStore'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog'
import { startSignInFlow, clearPendingOAuthState } from '@/modules/auth'
import { PREMIUM_FEATURES, type PremiumFeature } from './features'

export interface PremiumFeatureDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  feature: PremiumFeature
}

export function PremiumFeatureDialog({
  open,
  onOpenChange,
  feature
}: PremiumFeatureDialogProps): React.JSX.Element {
  const config = PREMIUM_FEATURES[feature]
  const Icon = config.icon
  const signingIn = useAuthStore((s) => s.signingIn)
  const setSigningIn = useAuthStore((s) => s.setSigningIn)

  async function handleSignIn() {
    onOpenChange(false)
    await startSignInFlow()
  }

  function handleCancelSignIn() {
    setSigningIn(false)
    clearPendingOAuthState()
    onOpenChange(false)
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <div className="flex items-center gap-3">
            <div className="rounded-full bg-primary/10 p-2">
              <Icon size={20} className="text-primary" />
            </div>
            <DialogTitle>{config.title}</DialogTitle>
          </div>
          <DialogDescription className="pt-2">{config.description}</DialogDescription>
        </DialogHeader>

        {config.bullets.length > 0 && (
          <ul className="mt-2 space-y-2 text-sm">
            {config.bullets.map((b) => (
              <li key={b} className="flex items-start gap-2">
                <Check size={16} className="mt-0.5 shrink-0 text-primary" />
                <span>{b}</span>
              </li>
            ))}
          </ul>
        )}

        <DialogFooter>
          {signingIn ? (
            <>
              <button
                type="button"
                className="inline-flex items-center justify-center rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors"
                onClick={handleCancelSignIn}
              >
                Cancel
              </button>
              <button
                type="button"
                className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50 transition-colors"
                disabled
              >
                <Loader2 size={16} className="mr-2 animate-spin" />
                Signing in&hellip;
              </button>
            </>
          ) : (
            <>
              <button
                type="button"
                className="inline-flex items-center justify-center rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors"
                onClick={() => onOpenChange(false)}
              >
                Maybe later
              </button>
              <button
                type="button"
                className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 transition-colors"
                onClick={handleSignIn}
              >
                <LogIn size={16} className="mr-2" />
                Sign in
              </button>
            </>
          )}
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
