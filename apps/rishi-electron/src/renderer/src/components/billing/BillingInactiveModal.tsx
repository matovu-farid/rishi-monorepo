import { useCallback, useState, type JSX } from 'react'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle
} from '@/components/ui/dialog'
import { workerFetch } from '@/lib/api'
import { useBillingStore } from '@/stores/billingStore'
import { getBillingStatusBucket, getBillingStatusCopy } from '@rishi/shared/billing/status'

export function BillingInactiveModal(): JSX.Element | null {
  const billingInactive = useBillingStore((s) => s.billingInactive)
  const subscriptionStatus = useBillingStore((s) => s.subscriptionStatus)
  const dismiss = useBillingStore((s) => s.dismiss)

  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const handleManage = useCallback(async (): Promise<void> => {
    setError(null)
    setLoading(true)
    try {
      const res = await workerFetch('/api/billing/start', {
        method: 'POST',
        body: JSON.stringify({})
      })
      if (res.status === 503) {
        setError("Billing isn't available in this build.")
        return
      }
      if (!res.ok) {
        setError("Couldn't reach the billing portal. Try again.")
        return
      }
      const data = (await res.json()) as { url?: string }
      if (!data.url) {
        setError("Couldn't reach the billing portal. Try again.")
        return
      }
      await window.electron.openExternal(data.url)
      // Dismiss after openExternal so the modal doesn't linger behind the
      // user's browser window when they come back to finish.
      dismiss()
    } catch (err: unknown) {
      console.warn('[billing-modal] manage failed:', err)
      setError("Couldn't reach the billing portal. Try again.")
    } finally {
      setLoading(false)
    }
  }, [dismiss])

  if (!billingInactive) return null

  const bucket = getBillingStatusBucket(subscriptionStatus)
  const copy = getBillingStatusCopy(bucket)

  return (
    <Dialog
      open={billingInactive}
      onOpenChange={(open) => {
        if (!open) dismiss()
      }}
    >
      <DialogContent data-testid="billing-inactive-modal" showCloseButton={false}>
        <DialogHeader>
          <DialogTitle data-testid="billing-inactive-title">{copy.title}</DialogTitle>
          <DialogDescription>{copy.body}</DialogDescription>
        </DialogHeader>

        {error ? (
          <p data-testid="billing-inactive-error" className="text-sm text-red-600">
            {error}
          </p>
        ) : null}

        <DialogFooter>
          <button
            type="button"
            data-testid="billing-inactive-dismiss"
            onClick={dismiss}
            className="inline-flex items-center justify-center rounded-lg border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 transition-colors"
          >
            Dismiss
          </button>
          <button
            type="button"
            data-testid="billing-inactive-manage"
            onClick={() => {
              void handleManage()
            }}
            disabled={loading}
            className="inline-flex items-center justify-center rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 transition-colors disabled:opacity-50"
          >
            {loading ? 'Opening…' : copy.ctaLabel}
          </button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export default BillingInactiveModal
