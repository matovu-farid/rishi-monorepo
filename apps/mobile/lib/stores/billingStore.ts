/**
 * T-P2.3 — BILLING-002 mobile billing store (RED phase placeholder).
 *
 * Holds the global "subscription required" modal state. `apiClient` sets
 * it on 402 BILLING_INACTIVE; the `<BillingInactiveModal />` reads it at
 * the app root.
 *
 * Currently a minimal Zustand slice so dependent red tests can
 * import / assert on the state surface. The real wiring (apiClient
 * integration + modal CTAs) lands in T-P2.3.
 */
import { create } from 'zustand'

interface BillingState {
  billingInactive: boolean
  subscriptionStatus: string | null
  setBillingInactive: (status: string | null) => void
  dismiss: () => void
}

export const useBillingStore = create<BillingState>()((set) => ({
  billingInactive: false,
  subscriptionStatus: null,
  setBillingInactive: (status) =>
    set({ billingInactive: true, subscriptionStatus: status }),
  dismiss: () => set({ billingInactive: false, subscriptionStatus: null }),
}))
