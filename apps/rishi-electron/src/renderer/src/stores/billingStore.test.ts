import { describe, it, expect, beforeEach } from 'vitest'
import { useBillingStore } from './billingStore'

describe('billingStore', () => {
  beforeEach(() => {
    useBillingStore.setState({
      billingInactive: false,
      subscriptionStatus: null
    })
  })

  it('starts with billingInactive=false and null status', () => {
    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(false)
    expect(s.subscriptionStatus).toBeNull()
  })

  it('setBillingInactive flips flag and records status', () => {
    useBillingStore.getState().setBillingInactive('past_due')
    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(true)
    expect(s.subscriptionStatus).toBe('past_due')
  })

  it('setBillingInactive accepts null status', () => {
    useBillingStore.getState().setBillingInactive(null)
    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(true)
    expect(s.subscriptionStatus).toBeNull()
  })

  it('dismiss clears flag and status', () => {
    useBillingStore.getState().setBillingInactive('canceled')
    useBillingStore.getState().dismiss()
    const s = useBillingStore.getState()
    expect(s.billingInactive).toBe(false)
    expect(s.subscriptionStatus).toBeNull()
  })
})
