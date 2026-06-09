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
  setBillingInactive: (status) => set({ billingInactive: true, subscriptionStatus: status }),
  dismiss: () => set({ billingInactive: false, subscriptionStatus: null })
}))
