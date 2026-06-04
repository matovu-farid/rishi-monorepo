/**
 * T-P2.3 — BILLING-002 BillingInactiveModal (RED phase placeholder).
 *
 * Final shape (per SPEC §3.2): a react-native `<Modal>` driven by
 * `useBillingStore`. Title "Subscription required", body referencing
 * `subscriptionStatus`, CTAs "Manage Subscription" (POST
 * `/api/billing/portal` → `WebBrowser.openBrowserAsync(url)`) and
 * "Dismiss" (calls `useBillingStore.dismiss()`).
 *
 * Currently a no-op placeholder so dependent red tests fail for
 * "wrong rendering" rather than "module not resolvable". Real
 * implementation lands in T-P2.3.
 */
import * as React from 'react'

export function BillingInactiveModal(): React.ReactElement {
  // Placeholder renders an empty host node so test-renderer's `.root`
  // remains accessible. The real implementation renders an RN <Modal>.
  return React.createElement('View', { testID: 'billing-modal-placeholder' })
}

export default BillingInactiveModal
